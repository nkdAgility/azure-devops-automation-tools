# Exports

Pristine snapshots exported from the client's servers. **Never edit files here** - working
copies being modified before re-import belong in the owning migration's `fix-work/` folder.
These snapshots are the before/after evidence and the diff baseline, shared by all migrations.

Convention: one dated folder per export run, split by format:

```
exports/<source>/<yyyyMMdd>/
├── xml/    # old-style exports: witadmin (work item types, categories, process configuration,
│           # global lists), process templates, ExportProjectTemplate.ps1 output
└── json/   # new-style exports: inherited process JSON (process-migrator, REST APIs)
```

`<source>` is the collection or organisation name. Create the folders with:

```powershell
New-ExportSnapshot -Source <CollectionOrOrgName>
```
