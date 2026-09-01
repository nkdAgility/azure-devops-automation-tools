# <Migration name> - engagement log

- **Type:** Azure DevOps Migration Tools (`devopsmigration.exe`) + repo/artifact engines
- **Source org/project(s):**
- **Target org/project(s):**
- **Key dates:** dry-run: / cutover:

## Workflow

1. Fill `migrate-repos-config.json` (repos/artifacts) and the `configuration-*.json` files
   (work items, pipelines). The repo/artifact engines authenticate with Entra by default;
   the `$ENV:AZDO_PAT_<ORG>` placeholders are optional fallbacks (unset variables are
   simply omitted). `devopsmigration.exe` cannot use Entra: its `configuration-*.json`
   `AccessToken` fields stay empty and are bound from the `MigrationTools__...__AccessToken`
   variables that `Set-AutomationSecrets` supplies from `..\..\secrets\secrets.json`.
2. `.\Sync.ps1 -WhatIf` to preview everything, then `.\Sync.ps1` to run: repos -> pipelines ->
   artifacts -> work items. Re-running is safe (idempotent engines skip what already moved).
3. `.\Run-Migrate-Artifacts.ps1 -Inventory` for a read-only inventory CSV before committing to
   package migration.
4. Commit the summary CSVs written to `output\` as engagement evidence.

## Commit mention linking (handled automatically, but know it is there)

Azure DevOps creates every repository with **Commit mention linking** and **Commit mention
work item resolution** on. A migration pushes the whole history at once, so the server reads
every historical `#1234` in every commit message as a new mention and links it. On one
engagement that created links across 6,800 work items across the whole organisation, because
work item ids are unique per organisation rather than per project.

`Run-Migrate-Repos.ps1` disables both before pushing and restores them afterwards, whatever
happens to the run. Nothing to configure.

**It depends on an endpoint Microsoft does not document.** These toggles are web-portal only
in the product documentation, so the engine calls the internal endpoint the settings page
uses (`_api/_versioncontrol/...`, not versioned REST). Microsoft may change or remove it
without notice. Every write is verified by re-reading it, and a mismatch **stops the
migration** rather than pushing with mentions live. If a run starts failing with a message
about repository options, that endpoint has most likely changed: check it before working
around it, and never disable the check to get a migration through.

## Renaming repos in transit

When the target names repositories by convention rather than by history - a governed
project, say, where every repo carries its hierarchy code - give the run a
`TargetRepoName` and the repository is created and pushed under that name:

```json
"Runs": [
  { "RepoName": "SourceRepoA", "TargetRepoName": "ABC-SourceRepoA" },
  { "RepoName": "SourceRepoB", "TargetRepoName": "ABC-DEF-SourceRepoB" }
]
```

Omit `TargetRepoName` and the repository keeps its source name. A rename applies to one
named repository, so it is only valid alongside `RepoName` - several renames are several
single-repo runs, which is what the `Runs` array is for. The `target_repo` column in
`output\repomigration.csv` records where each one landed.

## Run log

| Date | What ran | Result |
| ---- | -------- | ------ |
