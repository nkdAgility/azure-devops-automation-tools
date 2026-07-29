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

# ===========================================================================
# N. Custom link types - Azure DevOps Services rejects them.
#
# Deleting a link type also deletes every link of that type, permanently.
# Review the inventory with the customer BEFORE running the removal step: it
# is the only record of the relationships, and the basis for re-creating them
# as related links after the import.
# ===========================================================================
# Write-FixSection 'N. Remove custom link types'
#
# # Read-only: what exists, and what would be lost.
# Get-WorkItemLinkType -Collection $collection -CustomOnly | Format-Table Name, ReferenceName, Topology
# Export-WorkItemLinkInventory -Collection $collection
#
# # Destructive. Inventories each type to the export snapshot first, and
# # refuses to delete if that export fails.
# Invoke-FixStep -Name 'remove-linktype-Custom.Affects' -Action {
#     Remove-WorkItemLinkType -Collection $collection -ReferenceName 'Custom.Affects'
# } -Verify {
#     -not (Get-WorkItemLinkType -Collection $collection -ReferenceName 'Custom.Affects')
# }
