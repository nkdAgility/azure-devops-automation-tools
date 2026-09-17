# <Migration name> - engagement log

- **Type:** Azure DevOps repos -> GitHub (Migrate-ReposToGitHub.ps1 engine)
- **Source org:**
- **Target GitHub org:**
- **Key dates:** inventory: / approval received: / cutover:

## Workflow

1. Fill `github-repos-config.json`. Auth is ambient-first: Entra sign-in for the source
   and the signed-in gh CLI for GitHub, so no stored tokens are needed for interactive
   runs. The config's token fields stay as `$ENV:AZDO_PAT_<ORG>` / `$ENV:GITHUB_TOKEN`
   placeholders - fallbacks for unattended runs, supplied by `Set-AutomationSecrets`
   from `..\..\secrets\secrets.json` (the GitHub entry lists `GITHUB_TOKEN` in
   `EnvVars`). An unset fallback is fine.
2. `.\Run-Export-RepoInventory.ps1` builds `repo-inventory.csv`: every project, every git
   repo. Commit it, hand it to the customer to mark `Approved = yes` per repo (editing
   `TargetName` where the pre-filled slug is not wanted), and commit their edits.
3. `.\Sync.ps1 -WhatIf` to preview, then a single-repo smoke test
   (`.\Sync.ps1 -RepoFilter '<small repo>'`), then `.\Sync.ps1` for the full run:
   inventory refresh -> migrate approved rows (all branches, tags and LFS objects).
4. Re-run `.\Sync.ps1` any time: newly approved rows migrate, already-migrated repos
   re-sync idempotently (deltas only). Nothing on GitHub is ever deleted.
5. Commit `repo-inventory.csv`, `output\github-repomigration.csv` and
   `output\github-attention.md` after each run - they are the engagement evidence
   (the summary is also the rename-detection baseline, and the attention report is
   the one-place list of every repo that has not migrated, with full reasons).

## Rerun semantics

| Situation | Behaviour |
| --------- | --------- |
| Row not approved | Skipped; row retained in the CSV |
| Newly approved row | Migrated on the next run |
| Already migrated | Re-synced idempotently: create skipped, delta push, missing LFS only |
| `TargetName` edited after migration | `Blocked` until the CSV is reverted or reconciled with `-AcceptRenames` |
| Repo deleted from source | Marked `MissingFromSource`; `Skipped` even if approved |
| Run failed for a repo | Recorded `Failed: ...`; retried automatically on the next run |
| Blob over 100 MB (GitHub hard limit) | `Blocked`, and the file is recorded in `oversize-decisions.json` with action `pending`. With customer agreement set each file's action to `lfs` (rewrite into Git LFS) or `strip` (remove from history with git filter-repo) and re-run - the rewrite is deterministic, happens in a separate copy, and the source is never touched. GitHub commit ids diverge from the source; `lfs` consumes LFS quota. `LfsMigrateOversize: true` remains the blanket everything-to-LFS alternative. Commit the decisions file - it is the remediation record |

## Run log

| Date | What ran | Result |
| ---- | -------- | ------ |
