# ===========================================================================
# Data Import Tool scratchbook - <collection name here>.
#
# This is a SCRATCHBOOK: run it selection-by-selection in VS Code, not
# top-to-bottom. Each block is an independent Migrator.exe interaction; the
# validate/fix loop is: Prepare -> read validation logs -> fix (see
# DataImport-Cleanup.ps1) -> Prepare again -> compare summaries.
#
# 0. Setup - run this block first.
# ===========================================================================
. "$PSScriptRoot\..\..\init.ps1"
# Record this working session's console to output\runs\ (committed engagement history).
# Guarded so re-running this setup block does not open a second log; run the last
# section to close it.
if (-not $env:NKDA_RUNLOG) { Start-AutomationRunLog -Name 'DataImport-Scratchbook' -EngagementPath $PSScriptRoot }
$ErrorActionPreference = 'Stop'

# --- Environment-specific values -------------------------------------------
$collection       = 'http://your-tfs-server:8080/tfs/YourCollection/'
$tenantDomainName = 'yourtenant.com'
$region           = 'CUS'
$migratorPath     = 'C:\tools\DataMigrationTool\Migrator.exe'
$migrationName    = Split-Path -Leaf $PSScriptRoot
$outputPath       = Join-Path (Get-AutomationWorkspace).OutputFolder "$migrationName\DataImportTool"

Set-MigrationContext -Collection $collection -MigratorPath $migratorPath

# ===========================================================================
# 1. Prepare - generates the import specification (import.json) and the
#    validation log under $outputPath. Re-run after each round of fixes.
# ===========================================================================
Invoke-DataImportPrepare -TenantDomainName $tenantDomainName -Region $region -OutputPath $outputPath

# ===========================================================================
# 2. Validation summary - per-project/per-error-code counts from the latest
#    Prepare/Validate logs. Compare before/after a fix round.
# ===========================================================================
Get-DataImportValidationSummary -Path $outputPath

# ===========================================================================
# 3. Validate the completed import specification (fill in the generated
#    import.json first - see notes.md).
# ===========================================================================
# Invoke-DataImportValidate -TenantDomainName $tenantDomainName -Region $region
# & $migratorPath Import /importFile:"$PSScriptRoot\import.json" /validateOnly

# ===========================================================================
# Last. Close the run log - run when this working session is done. Exiting the
# PowerShell session also ends the transcript.
# ===========================================================================
Stop-AutomationRunLog
