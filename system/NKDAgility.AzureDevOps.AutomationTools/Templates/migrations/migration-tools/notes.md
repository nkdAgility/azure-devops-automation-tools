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
