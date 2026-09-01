## Migration capability

Azure DevOps migration engagements, across three toolchains: the Microsoft Data Import
Tool (`Migrator.exe` / `witadmin.exe`), the Azure DevOps Migration Tools, and the Azure
DevOps Migration Platform — plus Azure DevOps → GitHub repository migrations.

### Scaffolding an engagement

```powershell
New-Migration -Name <Name> -Type DataImport|MigrationTools|MigrationPlatform|GitHubRepos
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
  link of that type along with the definition. `Remove-WitWorkItemLinkType` inventories over
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

### Azure DevOps → GitHub repo migration

The `GitHubRepos` engagement type migrates git repositories (all branches, tags and LFS
objects — code only) from an Azure DevOps organisation into a GitHub organisation, driven
by a committed approval CSV:

1. `Run-Export-RepoInventory.ps1` enumerates every project and repo into
   `repo-inventory.csv` — commit it; the customer marks rows `Approved = yes` and may
   edit the pre-filled `TargetName`; commit their edits.
2. `Sync.ps1 -WhatIf` first, always. Then a single-repo smoke test
   (`Sync.ps1 -RepoFilter '<small repo>'`), then the full `Sync.ps1`.
3. Re-running is the workflow: newly approved rows migrate; already-migrated repos
   re-sync idempotently. Nothing on GitHub is ever deleted.

Authentication is **ambient identity first, stored token as fallback** — for this and for
every other engine (`Migrate-Repos`, `Migrate-Artifacts`, `Update-WikiWorkItemLinks`,
`Update-CommentAttachmentLinks`, `Set-WorkItemStartId`): Entra per Azure DevOps
organisation (`Get-AzureDevOpsAccessToken` — an Entra token works anywhere a PAT does,
REST and git alike, and is renewed per repository/feed/work-item batch across a long run),
the signed-in gh CLI for GitHub (`Get-GitHubAccessToken`, then `GITHUB_TOKEN`). PATs/tokens
in `secrets.json` are only used when ambient sign-in is unavailable — worth configuring for
unattended runs and required for organisations that are not Entra-backed, where every REST
command falls back to the secrets PAT for the collection automatically. The exception is
`devopsmigration.exe`, which cannot use Entra: its `configuration-*.json` `AccessToken`
env-var bindings stay PAT-fed by `Set-AutomationSecrets`.

**Which identity, per organisation.** A consultant holds one account per customer tenant,
so the organisation names the one to use: `SignInAs` on its `secrets.json` entry (a UPN,
not a secret), or `AZDO_SIGNIN_<ORG>` in CI. An entry with `SignInAs` and no `AccessToken`
is an Entra organisation — reported as such at load, never warned about. Sign-in stops at
the first source holding that account:

1. the signed-in **Azure CLI** (`az login`) — the store every runbook and doc points at,
   and one Az PowerShell cannot see;
2. an existing **Az PowerShell** context for that tenant;
3. an interactive sign-in, pinned to the tenant and to `SignInAs` so it neither lands on
   an account picker nor mints a token for whichever identity happened to be current.

The tenant is discovered from the collection, but Azure DevOps only returns
`X-VSS-ResourceTenant` on a response that actually challenges for authentication —
anonymous `connectionData` answers 203 without it. A collection is therefore only proved
non-Entra once the authenticated probe comes back empty too; treating the anonymous probe
as sufficient reports every organisation as non-Entra and silently downgrades to PATs.

Known gap: an interactive sign-in needs a window handle, so a headless host fails with
`A window handle must be configured` and there is no automatic device-code fallback yet.
Sign in first (`Connect-AzAccount -UseDeviceAuthentication -TenantId <id> -AccountId <upn>`)
or supply a PAT for unattended runs.

Rules:

- **Anything that writes to the GitHub organisation is destructive** — same standing as a
  `-Collection` write: preview first, never run unprompted.
- The inventory CSV and `output\github-repomigration.csv` are **committed engagement
  evidence** (the summary is also the next run's rename-detection baseline). Customer
  edits to `TargetName`/`Approved`/`Notes` are always preserved by inventory refreshes.
- A `TargetName` edited *after* its repo migrated is **Blocked**, not migrated twice —
  revert the CSV, or reconcile on GitHub and re-run with `-AcceptRenames`.
- Repos with blobs over GitHub's hard 100 MB limit are **Blocked**, not failed mid-push,
  and each offending file is recorded in the committed `oversize-decisions.json` with
  action `pending`. History rewrites are a customer decision: record it per file there —
  `lfs` (rewrite into Git LFS) or `strip` (remove from history via git filter-repo) — and
  re-run; the rewrite happens in a separate copy, the source is never touched, GitHub
  commit ids diverge and `lfs` consumes quota. `LfsMigrateOversize` is the blanket
  everything-to-LFS opt-in when per-file decisions are not needed.
- `output\github-attention.md` is the one-place, committed list of every approved repo
  that has not migrated, with full reasons and oversize object lists inlined. Refresh it
  by re-running `Sync.ps1`.
- **Never print, log or echo `GITHUB_TOKEN`** — the same secrets rules as PATs apply; git
  auth goes via `http.extraheader`, never in a remote URL.

### Reference shapes

Microsoft's `process-customization-scripts` repo holds the out-of-box template shapes the
Data Import Tool validates against. Fix values — TypeFields, categories, feedback states —
come from there. Verify state mappings against `Get-WitWorkItemTypeState` before running
`Repair-ProcessConfiguration`.

### Transports

Three, each with one private invoker that every public function goes through. Never call
`witadmin.exe` or `Invoke-RestMethod` directly from a public function.

| | witadmin / Migrator.exe | Azure DevOps REST | GitHub REST |
| - | - | - | - |
| Invoker | `Invoke-WitAdminFix` | `Invoke-AzureDevOpsApi` | `Invoke-GitHubApi` |
| Good for | schema and process definitions | the data itself: work items, links, queries, repos | GitHub repos: probe, create, configure |
