@{
    RootModule        = 'NKDAgility.AzureDevOps.AutomationTools.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = '691d41a2-3ab0-4105-86cd-d66496c014f3'
    Author            = 'Martin Hinshelwood'
    CompanyName       = 'naked Agility Limited'
    Copyright         = '(c) naked Agility Limited. All rights reserved.'
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
        'Rename-Field'
        # DataImportTool - process configuration XML
        'Export-ProcessConfigurationFixFile'
        'Import-ProcessConfigurationFixFile'
        'Update-ProcessConfigurationFixFile'
        'Add-ProcessConfigurationElement'
        'Set-ProcessConfigurationAttribute'
        'Add-ProcessConfigurationTypeField'
        'Set-ProcessConfigurationStates'
        'Set-ProcessConfigurationColumns'
        'Set-ProcessConfigurationAddPanel'
        # DataImportTool - work item types and categories
        'Get-WorkItemType'
        'Get-WorkItemTypeState'
        'Copy-WorkItemType'
        'Import-WorkItemTypeFile'
        'Add-WorkItemCategory'
        'Add-WorkItemCategoryType'
        'Remove-WorkItemCategoryType'
        # DataImportTool - rules and link types
        'Find-WitRuleScope'
        'Find-GlobalWorkflowRuleScope'
        'Remove-WitRuleScope'
        'Remove-GlobalWorkflowRuleScope'
        'Remove-WitFieldRule'
        'Remove-WorkItemLinkType'
        # WorkItemTracking - REST
        'Get-WorkItemLinkType'
        'Get-WorkItemLink'
        'Export-WorkItemLinkInventory'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('AzureDevOps', 'Migration', 'DataImportTool', 'witadmin')
            ProjectUri = 'https://github.com/nkdAgility/azure-devops-automation-tools'
        }
    }
}
