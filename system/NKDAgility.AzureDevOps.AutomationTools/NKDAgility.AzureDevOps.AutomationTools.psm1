# The module's own root. Every function that needs a file shipped with the module
# resolves it from here - never by walking up from $PSScriptRoot or ModuleBase.
# The module is copied out of this repo into a client workspace's .system\ folder,
# so anything above this folder does not exist at runtime.
$script:ModuleRoot = $PSScriptRoot

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
$public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)

foreach ($file in ($private + $public)) {
    . $file.FullName
}

# Back-compatible aliases for the witadmin commands renamed to the Wit noun-prefix.
# Runbooks in existing engagements were written against the old names and must keep
# working: a client workspace pins nothing, so the next init.ps1 hands them this module.
# New code should use the Wit names - the prefix is what says "this shells out to
# witadmin.exe" rather than going over REST.
# NOTE: 'Get-WorkItemType' is deliberately NOT aliased here. That name now belongs to
# the REST command of the same name; aliasing it would silently send a runbook line to
# a different transport. Callers that meant witadmin were updated to Get-WitWorkItemType.
$script:WitAliases = @{
    'Add-WorkItemCategory'               = 'Add-WitWorkItemCategory'
    'Add-WorkItemCategoryType'           = 'Add-WitWorkItemCategoryType'
    'Copy-WorkItemType'                  = 'Copy-WitWorkItemType'
    'Get-WorkItemTypeState'              = 'Get-WitWorkItemTypeState'
    'Import-WorkItemTypeFile'            = 'Import-WitWorkItemTypeFile'
    'Remove-WorkItemCategoryType'        = 'Remove-WitWorkItemCategoryType'
    'Remove-WorkItemLinkType'            = 'Remove-WitWorkItemLinkType'
    'Rename-Field'                       = 'Rename-WitField'
    'Find-GlobalWorkflowRuleScope'       = 'Find-WitGlobalWorkflowRuleScope'
    'Remove-GlobalWorkflowRuleScope'     = 'Remove-WitGlobalWorkflowRuleScope'
    'Export-ProcessConfigurationFixFile' = 'Export-WitProcessConfigurationFixFile'
    'Import-ProcessConfigurationFixFile' = 'Import-WitProcessConfigurationFixFile'
}
foreach ($alias in $script:WitAliases.GetEnumerator()) {
    Set-Alias -Name $alias.Key -Value $alias.Value -Scope Script
}
# @() matters: a hashtable KeyCollection does not bind to -Alias as a string array, and
# the aliases silently fail to export.
$aliasNames = @($script:WitAliases.Keys)

Export-ModuleMember -Function $public.BaseName -Alias $aliasNames
