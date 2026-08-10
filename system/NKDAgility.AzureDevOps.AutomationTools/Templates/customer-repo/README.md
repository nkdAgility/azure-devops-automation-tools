# Customer workspace

A private nkdAgility customer workspace. The engines it uses are declared in
`capabilities.json`; `init.ps1` copies each one into `.system\` and loads it.

## Running anything: always through init.ps1

Run every command through a **fresh shell** so `init.ps1` executes first — it pulls the
engines and refreshes `.system\` before your command runs:

```powershell
pwsh -NoProfile -Command ". .\init.ps1; <your command>"
```

Why this matters: the engines run from `.system\`, which is only refreshed when
`init.ps1` runs. A PowerShell window that has been open all day keeps serving
yesterday's engine — even after a `git pull` — because runbooks skip init when the
module is already loaded. A fresh shell makes stale-engine bugs impossible.

For an interactive session (VS Code, selection-by-selection runbooks), the same rule in
different clothes: open a **new** terminal and dot-source init first:

```powershell
. .\init.ps1
```

`-NoSync` skips the git pull for offline work; everything still materialises from the
local clones.

## Where things live

| Path | What |
| ---- | ---- |
| `capabilities.json` | Which nkdAgility engines this workspace uses — yours to edit |
| `.system\` | Generated engine copies. Read-only, gitignored, **never edit** |
| `secrets\secrets.json` | Gitignored PATs; `secrets.example.json` shows the shape |
| `migrations\NN-<Name>\` | One folder per engagement |
| `output\` | Gitignored logs, checkpoints and scratch |

See `CLAUDE.md` for the full safety rules and this customer's specifics.
