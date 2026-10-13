# NKDAgility.AzureDevOps.AutomationTools

PowerShell module with the automation tasks used when migrating Azure DevOps data. Currently focused on the Azure DevOps Data Import Tool workflow (server → services); Migration Tools and Migration Platform tasks will move in over time.

## Usage

From the repo root (or a client runbook):

```powershell
Import-Module .\system\NKDAgility.AzureDevOps.AutomationTools -Force
Set-MigrationContext -Collection 'http://tfs:8080/tfs/DefaultCollection/' -MigratorPath 'C:\tools\DataMigrationTool\Migrator.exe'
```

`Set-MigrationContext` stores session defaults and applies them via `$Global:PSDefaultParameterValues`, so subsequent calls don't need to repeat `-Collection` etc. `-Project` is only defaulted on commands where it is mandatory, so commands with an optional `-Project` (e.g. `Find-WitGlobalWorkflowRuleScope`) keep collection scope unless told otherwise. `Clear-MigrationContext` undoes it.

## Run logs

Every runbook records its whole console, and that run history is committed with the engagement.

```powershell
. "$PSScriptRoot\..\..\init.ps1"
Start-AutomationRunLog -Name 'Sync'
try {
    # runbook body
}
finally { Stop-AutomationRunLog }
```

- **Where.** `Start-AutomationRunLog` starts `Start-Transcript -IncludeInvocationHeader` at `<engagement>\output\runs\<Name>-<yyyyMMdd-HHmmss>.log`. The engagement folder is the calling script's folder; pass `-EngagementPath` when calling from anywhere else. It must come after `init.ps1`, which loads the module.
- **Failed runs are kept.** `Stop-AutomationRunLog` sits in `finally`, so a run that throws still closes its log with everything up to the failure.
- **Nesting.** A runbook called by another (`Sync.ps1` → `Run-Migrate-Repos.ps1`) writes into its caller's log instead of starting its own. The handoff is in environment variables (`NKDA_RUNLOG`, `NKDA_RUNLOG_DEPTH`, `NKDA_RUNLOG_PID`), not module state, because each runbook re-imports the module through `init.ps1`; it also reaches child `pwsh` processes. Only the outermost `Stop-AutomationRunLog` in the process that started the log stops it. Variables left by a process that no longer exists are discarded and a fresh log starts.
- **Tool logs.** `Copy-AutomationRunLogArtifact -Path <file or folder> [-As <name>]` copies something that belongs to the run into `<log-basename>\<name>\` next to the log, and does nothing when no log is active or the path is missing. The migration-tools `Sync.ps1` uses it for devopsmigration.exe, which writes its log folder beside its own exe (inside the WinGet package folder; [migration-tools #3216](https://github.com/nkdAgility/azure-devops-migration-tools/issues/3216)) and names it in a `Logpath: <path>` line at startup on every run (and in `Check the logs for errors: <path>` on some exits, though not on a validation failure); the template reads either, so the tool's logs are kept for failed runs too.
- **Native output is recorded.** On PowerShell 7 (verified on 7.6), a transcript records a native exe's stdout and stderr, whether the call is at statement level or inside an engine function, so git, az, npm, mvn and dotnet output reaches the log without wrapping. `tests/RunLog.Tests.ps1` runs git under a transcript in a real console to keep that true. What a log cannot show: output an engine sends to a file (`2>$stderrFile`) or captures into a variable, and git's live progress meter, which git prints only to an interactive terminal. The templates still pipe devopsmigration.exe and devopsmigrationdev through `ForEach-Object`, because they read each line, for `[ERR]` and for the `Logpath:` / `Check the logs for errors:` path.
- **Selection-by-selection runbooks** (the data-import scratchbook and cleanup) start the log in their setup block, guarded by `if (-not $env:NKDA_RUNLOG)` so re-running setup does not nest, and close it in a final section. The log covers the working session.
- **Secrets.** A transcript is committed, so nothing may print a token. `init.ps1`, `Set-AutomationSecrets`, `Get-AzureDevOpsAccessToken` and the engines report variable names and auth *modes*, never values; `tests/RunLog.Tests.ps1` pushes a fake token through `init.ps1` and `Set-AutomationSecrets -Verbose` and asserts it never reaches a transcript. Keep it that way in new code and runbooks: never `Write-Host` a header, an `Organisation` object with PATs merged in, or an environment variable's value.
- **Git.** The customer `.gitignore` ignores only the repo-level `/output/` and carries `!/migrations/*/output/runs/`, so run logs are committed. Commit them after each run.

### Adopting run logs in an existing engagement

Templates are seeds: `New-Migration` copies them once and never again, so existing engagements do not pick this up from a module update. After `init.ps1` has loaded a module that includes these functions:

1. Preview, then wire the engagement's runbooks with the helper. It inserts `Start-AutomationRunLog` + `try {` after the `init.ps1` line and appends `finally { Stop-AutomationRunLog }`, or converts an engagement-local `Start-RunLog.ps1` / `Stop-RunLog` / `Copy-RunLogArtifact` to the module functions. It skips runbooks already wired, runbooks with no `init.ps1` line and selection-by-selection runbooks, and refuses a change that would not parse.

   ```powershell
   Get-ChildItem .\migrations\03-Example\*.ps1 | Enable-AutomationRunLog -WhatIf
   Get-ChildItem .\migrations\03-Example\*.ps1 | Enable-AutomationRunLog
   ```

2. In a migration-tools `Sync.ps1`, copy the `$toolLogDir` capture and `Copy-AutomationRunLogArtifact` call from the template's `Invoke-DevOpsMigration` by hand. Route any direct native tool call through the host as above.
3. Wire selection-by-selection runbooks by hand from the data-import templates.
4. Check the workspace `.gitignore` (a seed too): it must not ignore `migrations/*/output/` — add `!/migrations/*/output/runs/` under `/output/`.
5. Delete the engagement-local `Start-RunLog.ps1` once nothing dot-sources it, review the diff, and commit.

## Repository migration runbooks

The `MigrationTools` repository runbook reads its `migrate-repos-config.json` and runs every entry in `Runs` by default. Pass `-Repo <source repository name>` to run exactly one configured entry. Matching is exact and case-insensitive; no match or duplicate matches stop before the migration engine runs. `-WhatIf` previews the selected run. A selected run writes `output/repomigration-<repo>.csv` so it does not replace the full-run `output/repomigration.csv`. The runbook calls `init.ps1` on every invocation to sync and load the configured engines.

## Historical build, pipeline, and release artifacts

The standalone `Engines/Migrate-PipelineArtifacts.ps1` inventories artifact metadata, and `Engines/Publish-PipelineArtifacts.ps1` selects files and publishes them as [Universal Packages](https://learn.microsoft.com/en-us/azure/devops/artifacts/quickstarts/universal-packages?view=azure-devops). A client workspace supplies one `Run-Migrate-PipelineArtifacts.ps1` runbook, source and target organisations, PATs, CSV paths, and an ordered YAML configuration. Run the client runbook rather than the shared engines directly.

The inventory applies extension include/exclude globs, branch include/exclude globs, and a filename regex with named `product`, `version`, and `format` captures. It writes candidate, product-summary, coverage, and error CSVs. It lists build, pipeline, and release artifacts. Container build artifact files can become publish candidates; pipeline artifacts without file-level expansion remain in coverage, and release references to build files are not uploaded twice. Review coverage and errors to see what the inventory could not turn into candidates.

Publishing selects the highest source revision for each product, format, and normalized package version, breaking ties by build ID. Four numeric source parts map to three numeric package parts, and prerelease labels remain separate. For example, the latest `2.13.0.4.zip` file maps to package version `2.13.0` while keeping its original filename and bytes. The client YAML maps product globs to feeds and ranks formats: the highest-ranked format owns the plain product package name, and additional formats receive a suffix. The UM client runbook ranks NuGet variants ahead of ZIP.

The publisher checks the target feed before writing its action-only CSV. It omits superseded and already-published versions, and removes each row after a successful upload. A retry rebuilds the queue from the inventory and target feed. It checks again before each upload. During publishing, one progress bar shows the current package name, version, original filename, completed uploads, skipped actions, remaining actions, elapsed time, and estimated time left. Azure CLI output is captured so it does not redraw the bar. The console retains a start and final summary without one line per file. Counts and time apply to the current run; a resumed run starts with only its remaining actions. Container file downloads use each item's `contentLocation`, with a byte-count check before `az artifacts universal publish`. A package version already published under a previous format-suffixed name is reported as a conflict so the operator can reconcile it. Azure Artifacts package versions are immutable, so the publisher never overwrites one.

### Client runbook workflow

In a client workspace that has a `Run-Migrate-PipelineArtifacts.ps1` binder, run these from the workspace root, using that engagement's folder:

```powershell
& .\migrations\NN-Engagement\Run-Migrate-PipelineArtifacts.ps1 -WhatIf
& .\migrations\NN-Engagement\Run-Migrate-PipelineArtifacts.ps1 -Refresh -WhatIf
& .\migrations\NN-Engagement\Run-Migrate-PipelineArtifacts.ps1 -Publish
```

The first command reuses the candidate inventory if present and creates a plan; without an inventory it scans the source. The second forces a new source scan, replacing its candidate and coverage CSVs. The third reuses the inventory by default and uploads only selected versions still absent from the target feed. No switch behaves like `-WhatIf`. A failed or interrupted publish can be rerun: the feed is checked again, and successful uploads leave the plan. These commands do not migrate Azure Artifacts feed packages; `Migrate-Artifacts.ps1` owns that separate workflow.

Planning needs target feed read access and a target PAT even with `-WhatIf`. A source scan or publish also needs source access. Uploads need Azure CLI and its Azure DevOps extension. A blocked source row stops a complete `-Publish`; `-AllowPartial` publishes the ready rows. The action-only plan omits blocked rows, so read the console count and inventory coverage/error CSVs. `-MaxBuilds` and `-MaxReleases` can limit a deliberate `-Refresh` sample, but that sample replaces the current candidate inventory.

The client YAML config has this shape; the product and feed names are placeholders:

```yaml
extensions:
  include:
    - .zip
    - .nupkg
    - .nuspec
    - .nspec
  exclude: []
filePattern: '^(?<product>.+?)[.-](?<version>\d+\.\d+\.\d+(?:\.\d+)*(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?)\.(?<format>[A-Za-z0-9]+)$'
branches:
  include:
    - refs/heads/main
    - refs/heads/master
    - <none>
  exclude: []
targetOrg: 'https://dev.azure.com/example'
targetProject: 'ExampleProject'
formatPrecedence:
  - '*nupkg'
  - '*nuspec'
  - '*nspec'
  - '.zip'
  - '*'
feedMappings:
  - productPattern: '*'
    feed: 'ExampleFeed'
```

Extension and branch filters use include/exclude globs with exclusions taking precedence. Branch patterns match the full `Branch` CSV value, and `<none>` represents missing branch metadata. `filePattern` must capture `product`, `version`, and `format`. Feed mappings are first match wins. Format precedence is first matching pattern wins; NuGet variants can therefore own the plain product package name, ZIP gets `.zip` when it is an additional format, and `*` ranks other formats last.

Typical client evidence files are `pipeline-artifact-candidates.csv` (source files and branch), `pipeline-artifact-products.csv` (product summary), `pipeline-artifact-coverage.csv` (unexpanded or unmatched artifacts), `pipeline-artifact-errors.csv`, and `pipeline-artifact-publish-plan.csv` (remaining upload actions). Do not infer complete migration from an empty plan alone: inspect coverage, errors, and the blocked count, then validate package downloads in the target feed.

Typical per-project fix sequence, wrapped in checkpointed steps so each action is validated once and skipped on re-run:

```powershell
Set-MigrationContext -CheckpointPath '.\data\debug\DataImportTools\fix-steps.checkpoint.json'

# Baseline: what does the latest validation run say?
Get-DataImportValidationSummary -Path '.\data\debug\DataImportTools\output\Logs\MyCollection' | Select-Object -Expand Projects

# Check the actual workflow states first - Repair-ProcessConfiguration's defaults must match them
Get-WitWorkItemTypeState -Project 'MyProject' -WorkItemType 'User Story' | Format-Table -AutoSize
Get-WitWorkItemTypeState -Project 'MyProject' -WorkItemType 'Task' | Format-Table -AutoSize

Invoke-FixStep -Name 'myproject-feedback-types' -Action {
    Install-FeedbackWorkItemTypes -Project 'MyProject' -TypeDefinitionsPath '..\process-customization-scripts\Import\Agile\WorkItem Tracking\TypeDefinitions'
} -Verify { (Get-WitWorkItemType -Project 'MyProject') -contains 'Feedback Request' }

Invoke-FixStep -Name 'myproject-process-config' -Action {
    Repair-ProcessConfiguration -Project 'MyProject' -Path '.\fix-work\MyProject.ProcessConfiguration.xml'
}

# After a batch: re-run Prepare and compare the summary - fixed projects should drop to zero
Invoke-DataImportPrepare -TenantDomainName 'example.com' -OutputPath '.\output'
Get-DataImportValidationSummary -Path '.\data\debug\DataImportTools\output\Logs\MyCollection' | Select-Object -Expand Projects
```

Values used by the fix functions (TypeFields refnames, categories, feedback states) are taken from the out-of-the-box templates in Microsoft's [process-customization-scripts](https://github.com/Microsoft/process-customization-scripts) repo — keep it cloned as a sibling of this repo and use it as the reference for what "valid" looks like, changing the minimum needed so the customer's customisations are preserved.

## Structure

- `Public/Common/` — session context (`Set-MigrationContext`, `Get-MigrationContext`, `Clear-MigrationContext`) and the checkpointed step runner (`Invoke-FixStep`)
- `Public/DataImportTool/` — `Migrator.exe` wrappers (`Invoke-DataImportPrepare`, `Invoke-DataImportValidate`), validation log parsing (`Get-DataImportValidationSummary`), task-level fixes (`Install-FeedbackWorkItemTypes`, `Repair-ProcessConfiguration`), and the witadmin / process-configuration primitives
- `Private/` — path resolution and witadmin invocation helpers (not exported)

One function per file; the file name matches the function name. The `.psm1` dot-sources everything and exports only `Public/**`. When adding a public function, also add it to `FunctionsToExport` in the `.psd1`.

## Conventions

- Verb-Noun names, `[CmdletBinding()]`, mandatory parameters for anything that targets a server.
- Fix functions are idempotent where possible: re-running an already-applied fix reports "no change" instead of failing.
- Functions that mutate a collection write a `[fix]` step line for every action so runbook output doubles as an audit trail.
- Never log or echo PAT tokens or connection strings containing credentials.
