@{
    RootModule        = 'NKDAgility.AzureDevOps.AutomationTools.psm1'
    ModuleVersion     = '0.4.0'
    GUID              = '691d41a2-3ab0-4105-86cd-d66496c014f3'
    Author            = 'Martin Hinshelwood'
    CompanyName       = 'naked Agility Limited'
    Copyright         = '(c) 2026 naked Agility Limited. Licensed under the GNU AGPL v3.'
    Description       = 'Automation tasks used when migrating Azure DevOps data with the Azure DevOps Data Import Tool, the Azure DevOps Migration Tools, or the Azure DevOps Migration Platform.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        # Common
        'Get-MigrationContext'
        'Set-MigrationContext'
        'Clear-MigrationContext'
        'Invoke-FixStep'
        'Write-FixSection'
        # Common - logging
        'Initialize-AutomationLogging'
        'Write-InfoLog'
        'Write-DebugLog'
        'Write-ErrorLog'
        # Common - organisations and secrets
        'Get-Organisation'
        'Get-AzureDevOpsAuthHeader'
        'Get-AzureDevOpsAccessToken'
        'Set-AutomationSecrets'
        # Common - workspace
        'Initialize-AutomationWorkspace'
        'Get-AutomationWorkspace'
        # Common - scaffolding
        'New-AutomationWorkspace'
        'New-Migration'
        'New-ExportSnapshot'
        # DataImportTool - Migrator.exe
        'Invoke-DataImportPrepare'
        'Invoke-DataImportValidate'
        'Get-DataImportValidationSummary'
        # DataImportTool - task-level fixes
        'Install-FeedbackWorkItemTypes'
        'Repair-ProcessConfiguration'
        # DataImportTool - fields
        'Rename-WitField'
        'Add-WitReflectedWorkItemIdField'
        # DataImportTool - process configuration XML
        'Export-WitProcessConfigurationFixFile'
        'Import-WitProcessConfigurationFixFile'
        'Update-ProcessConfigurationFixFile'
        'Add-ProcessConfigurationElement'
        'Set-ProcessConfigurationAttribute'
        'Add-ProcessConfigurationTypeField'
        'Set-ProcessConfigurationStates'
        'Set-ProcessConfigurationColumns'
        'Set-ProcessConfigurationAddPanel'
        # DataImportTool - work item types and categories
        'Get-WitWorkItemType'
        'Get-WitWorkItemTypeState'
        'Copy-WitWorkItemType'
        'Import-WitWorkItemTypeFile'
        'Add-WitWorkItemCategory'
        'Add-WitWorkItemCategoryType'
        'Remove-WitWorkItemCategoryType'
        # DataImportTool - rules and link types
        'Find-WitRuleScope'
        'Find-WitGlobalWorkflowRuleScope'
        'Remove-WitRuleScope'
        'Remove-WitGlobalWorkflowRuleScope'
        'Remove-WitFieldRule'
        'Remove-WitWorkItemLinkType'
        # WorkItemTracking - REST
        'Get-WorkItemType'
        'Get-WorkItemLinkType'
        'Get-WorkItemLink'
        'Export-WorkItemLinkInventory'
        # GitMigration - REST (Azure DevOps + GitHub)
        'Get-TeamProject'
        'Get-GitRepository'
        'Get-GitHubRepository'
        'Get-GitHubAccessToken'
        'Export-GitRepoInventory'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @(
        # Pre-Wit-prefix names, kept so existing engagement runbooks keep working.
        'Add-WorkItemCategory'
        'Add-WorkItemCategoryType'
        'Copy-WorkItemType'
        'Get-WorkItemTypeState'
        'Import-WorkItemTypeFile'
        'Remove-WorkItemCategoryType'
        'Remove-WorkItemLinkType'
        'Rename-Field'
        'Find-GlobalWorkflowRuleScope'
        'Remove-GlobalWorkflowRuleScope'
        'Export-ProcessConfigurationFixFile'
        'Import-ProcessConfigurationFixFile'
    )
    PrivateData       = @{
        PSData = @{
            Tags       = @('AzureDevOps', 'Migration', 'DataImportTool', 'witadmin')
            ProjectUri = 'https://github.com/nkdAgility/azure-devops-automation-tools'
            LicenseUri = 'https://github.com/nkdAgility/azure-devops-automation-tools/blob/main/LICENSE'
            ReleaseNotes = 'https://github.com/nkdAgility/azure-devops-automation-tools/releases'
        }
    }
}
