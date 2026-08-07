
> **Generated block — do not edit.** Rendered by `. .\init.ps1` from the engines listed in
> `capabilities.json`. To change this text, edit it in the engine repo it came from.

## What this repo is

A private nkdAgility **customer workspace**. It holds this customer's data, configs,
runbooks and export snapshots under source control. The tooling itself is not kept here:
`capabilities.json` names the nkdAgility engines this workspace uses, and `init.ps1`
copies each one into `.system/`.

## Layout

| Path | Purpose |
| ---- | ------- |
| `init.ps1` | Per-session loader: syncs each engine clone, copies the modules into `.system/`, refreshes framework-owned files, renders this guidance, imports and initialises. Runbooks dot-source it. `-NoSync` for offline work |
| `capabilities.json` | Which engines this workspace uses. Yours to edit — add an entry to take on a capability |
| `.system/` | **Generated and read-only.** Engine modules copied in by `init.ps1`. Gitignored. Never edit — see the safety rules above |
| `workspace.json` | Committed machine-independent config (data/output/exports folders, API versions) |
| `workspace.local.json` | Gitignored machine overrides (`enginePaths` for engine development) |
| `secrets/secrets.json` | Gitignored PATs; `secrets.example.json` shows the shape |
| `data/` | Committed data files (`organisations.json` — no PATs) |
| `exports/<source>/<yyyyMMdd>/{xml,json}/` | Committed pristine server-export snapshots — never edited |
| `migrations/NN-<Name>/` | One self-contained folder per engagement |
| `output/` | Gitignored: logs, checkpoints, scratch |

## Seed files versus managed files

Two different lifecycles, and mixing them up loses work:

- **Seed** — copied once at scaffold time, then yours. Engagement runbooks,
  `workspace.json`, `capabilities.json`, `data/organisations.json`, governance programs.
  Engine improvements never reach them; each engagement folder records what produced it
  in `.template.json`.
- **Managed** — overwritten from the engine on every `init.ps1`. Listed in each engine's
  `Templates/customer-repo/.managed`, and each carries a header saying so. Editing one
  here is always lost; edit it in the engine repo instead.

This block, `AGENTS.md` and `.github/copilot-instructions.md` are rendered the same way.
Anything you write outside the markers survives; anything inside them does not.

## Committed output policy

Inventory and summary CSVs under `migrations/*/output/` are engagement evidence — commit
them. Logs and scratch stay in the repo-level gitignored `output/`.
