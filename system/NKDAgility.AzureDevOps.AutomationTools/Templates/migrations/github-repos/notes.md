# <Migration name> - engagement log

- **Type:** Azure DevOps repos -> GitHub (Migrate-ReposToGitHub.ps1 engine)
- **Source org:**
- **Target GitHub org:**
- **Key dates:** inventory: / approval received: / cutover:

## Workflow

1. Fill `github-repos-config.json`. Tokens stay as `$ENV:AZDO_PAT_<ORG>` /
   `$ENV:GITHUB_TOKEN` placeholders - `Set-AutomationSecrets` supplies them from
   `..\..\secrets\secrets.json` (the GitHub entry lists `GITHUB_TOKEN` in its `EnvVars`).
2. `.\Run-Export-RepoInventory.ps1` builds `repo-inventory.csv`: every project, every git
   repo. Commit it, hand it to the customer to mark `Approved = yes` per repo (editing
   `TargetName` where the pre-filled slug is not wanted), and commit their edits.
3. `.\Sync.ps1 -WhatIf` to preview, then a single-repo smoke test
   (`.\Sync.ps1 -RepoFilter '<small repo>'`), then `.\Sync.ps1` for the full run:
   inventory refresh -> migrate approved rows (all branches, tags and LFS objects).
4. Re-run `.\Sync.ps1` any time: newly approved rows migrate, already-migrated repos
   re-sync idempotently (deltas only). Nothing on GitHub is ever deleted.
5. Commit `repo-inventory.csv` and `output\github-repomigration.csv` after each run -
   they are the engagement evidence, and the summary is also the rename-detection
   baseline for the next run.

## Rerun semantics

| Situation | Behaviour |
| --------- | --------- |
| Row not approved | Skipped; row retained in the CSV |
| Newly approved row | Migrated on the next run |
| Already migrated | Re-synced idempotently: create skipped, delta push, missing LFS only |
| `TargetName` edited after migration | `Blocked` until the CSV is reverted or reconciled with `-AcceptRenames` |
| Repo deleted from source | Marked `MissingFromSource`; `Skipped` even if approved |
| Run failed for a repo | Recorded `Failed: ...`; retried automatically on the next run |
| Blob over 100 MB (GitHub hard limit) | `Blocked`, offending objects listed next to the clone; consider `git lfs migrate` on the source (history rewrite - customer decision) |

## Run log

| Date | What ran | Result |
| ---- | -------- | ------ |
