# CLAUDE.md

Guidance for Claude Code (and other AI assistants) working in this customer repository.

> This file is **co-owned**. Everything above the managed block is yours: add this
> customer's specifics, engagement history and quirks freely. The managed block at the
> bottom is refreshed from the automation tools module on every `. .\init.ps1` — do not
> edit inside the markers, the change will be lost.

## This customer

_Replace this section: source collection / target organisation, engagement history,
known quirks, anything the next person needs before touching the data._

## Safety rules — always apply

These are repeated deliberately so they are present even before `init.ps1` has ever run
in a fresh clone. Never rely on the managed block below for a safety rule.

- **Live systems.** Runbooks mutate live customer TFS/Azure DevOps instances. Anything
  that writes to a `-Collection` or organisation URL is destructive — do not run it
  unprompted, and never run a whole fix file against production without review.
- **Selection-by-selection.** `DataImport-Cleanup.ps1` and its siblings are run one
  section at a time in VS Code, never top-to-bottom. Preserve their sectioned structure.
- **Custom link type deletion is irreversible.** `witadmin deletelinktype` destroys every
  link of that type along with the definition. `Remove-WitWorkItemLinkType` inventories
  first for a reason; never pass `-NoExport` to make an error go away.
- **Secrets.** `secrets/secrets.json` is gitignored and must stay so. Never print, log,
  echo or commit a PAT; never add a `pat` value to `data/organisations.json`. When
  debugging auth, report header/variable *presence*, never values.
- **Exports are pristine.** Never modify anything under `exports/` — edit copies in the
  owning migration's `fix-work/`.
- **`.system/` is generated — never edit it.** It holds engine code copied in by
  `init.ps1` and is overwritten on every run, so an edit there is destroyed without
  trace. Make the change in the tools clone
  (`%USERPROFILE%\source\repos\azure-devops-automation-tools`, or the `toolsPath` in
  `workspace.local.json`) and re-run `. .\init.ps1`. The files are read-only, a hook
  refuses writes into the folder, and `init.ps1` stops rather than discarding a
  hand-edit — but do not rely on being caught.

<!-- BEGIN managed: nkdagility -->
<!-- END managed: nkdagility -->
