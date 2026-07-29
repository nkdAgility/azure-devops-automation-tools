# ===========================================================================
# Data Import Tool cleanup runbook - <collection name here>.
#
# Sectioned fix runbook: run SELECTION-BY-SELECTION in VS Code, not
# top-to-bottom. Run section 0 first, then any fix section on its own. Keep
# every section idempotent and independently runnable; note ordering
# constraints and the witadmin/migrator error codes each section addresses
# (TF400526, TF402538, VS237302, ...) in its comments.
#
# 0. Setup - run this block first.
# ===========================================================================
. "$PSScriptRoot\..\..\init.ps1"

# Stop on the first error: a failed fix aborts the rest of the selection
# instead of carrying on against the live collection.
$ErrorActionPreference = 'Stop'

# --- Environment-specific values -------------------------------------------
$collection           = 'http://your-tfs-server:8080/tfs/YourCollection/'
$migrationName        = Split-Path -Leaf $PSScriptRoot
$fixWorkFolder        = Join-Path $PSScriptRoot 'fix-work'
$checkpointPath       = Join-Path $fixWorkFolder 'fix-steps.checkpoint.json'
$agileTypeDefinitions = Join-Path $env:USERPROFILE 'source\repos\process-customization-scripts\Import\Agile\WorkItem Tracking\TypeDefinitions'

New-Item -ItemType Directory -Path $fixWorkFolder -Force | Out-Null
Set-MigrationContext -Collection $collection -CheckpointPath $checkpointPath

# ===========================================================================
# 1. <First fix section - name the error code it addresses, e.g. TF400526>
# ===========================================================================
# Write-FixSection '1. Example: rename a conflicting field (TF400526)'
# Invoke-FixStep -Name 'rename-System.AreaId' -Action {
#     Rename-Field -ReferenceName 'System.AreaId' -NewName 'Area ID'
# } -Verify {
#     # return $true when the fix is confirmed on the server
# }
