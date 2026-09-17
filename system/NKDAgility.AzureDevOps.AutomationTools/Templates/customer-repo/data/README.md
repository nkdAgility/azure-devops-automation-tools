# Data

Committed inputs for the automation scripts: `organisations.json` plus any per-engagement data
files (`fields.json` + `fields/`, `pages/`, `templates/`, `ReflectedWorkItemId.json`, ...).

- **Never put PATs in these files.** `organisations.json` is committed without a `pat` property;
  tokens live in the gitignored `secrets/secrets.json` and are resolved at load time by
  `Get-Organisation` / `Set-AutomationSecrets`.
- File-shape examples for every supported data file live in the tools repo under
  `azure-devops-automation-tools\data\sample\`.
