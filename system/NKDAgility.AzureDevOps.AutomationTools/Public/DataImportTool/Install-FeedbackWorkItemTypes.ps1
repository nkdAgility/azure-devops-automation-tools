function Install-FeedbackWorkItemTypes {
    <#
    .SYNOPSIS
    Ensures the work item types and categories that ProjectProcessConfiguration requires
    exist in a project: Task category, Feedback Request/Response types and categories.

    .DESCRIPTION
    Addresses the Data Import Tool prerequisites behind TF400526 (ProcessConfiguration
    requires FeedbackRequestWorkItems/FeedbackResponseWorkItems) and TF400517 (every type
    in Microsoft.RequirementCategory must carry the Effort field). The feedback types are
    added to Microsoft.HiddenCategory, and Bug is removed from Microsoft.RequirementCategory
    unless -KeepBugInRequirementCategory is passed.

    Run this BEFORE Repair-ProcessConfiguration for the same project.

    .PARAMETER TypeDefinitionsPath
    Folder containing FeedbackRequest.xml and FeedbackResponse.xml, e.g. the OOB Agile
    template's 'WorkItem Tracking\TypeDefinitions' folder from process-customization-scripts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$TypeDefinitionsPath,
        [switch]$KeepBugInRequirementCategory,
        [string]$RequirementWorkItemType = 'User Story',
        [string]$WitAdminPath
    )

    if (-not (Test-Path -LiteralPath $TypeDefinitionsPath -PathType Container)) {
        throw "Type definitions folder '$TypeDefinitionsPath' does not exist."
    }

    Write-FixStep "Installing feedback work item types and categories in '$Project'"
    Add-WorkItemCategory -Collection $Collection -Project $Project -ReferenceName 'Microsoft.TaskCategory' -Name 'Task Category' -DefaultWorkItemType 'Task' -WitAdminPath $WitAdminPath
    # The RequirementCategory is required by the process configuration import and
    # is absent from some projects (observed: sparse Scrum-derived category files).
    Add-WorkItemCategory -Collection $Collection -Project $Project -ReferenceName 'Microsoft.RequirementCategory' -Name 'Requirement Category' -DefaultWorkItemType $RequirementWorkItemType -WitAdminPath $WitAdminPath
    Import-WorkItemTypeFile -Collection $Collection -Project $Project -Path (Join-Path $TypeDefinitionsPath 'FeedbackRequest.xml') -WitAdminPath $WitAdminPath
    Import-WorkItemTypeFile -Collection $Collection -Project $Project -Path (Join-Path $TypeDefinitionsPath 'FeedbackResponse.xml') -WitAdminPath $WitAdminPath
    Add-WorkItemCategory -Collection $Collection -Project $Project -ReferenceName 'Microsoft.FeedbackRequestCategory' -Name 'Feedback Request Category' -DefaultWorkItemType 'Feedback Request' -WitAdminPath $WitAdminPath
    Add-WorkItemCategory -Collection $Collection -Project $Project -ReferenceName 'Microsoft.FeedbackResponseCategory' -Name 'Feedback Response Category' -DefaultWorkItemType 'Feedback Response' -WitAdminPath $WitAdminPath
    Add-WorkItemCategoryType -Collection $Collection -Project $Project -ReferenceName 'Microsoft.HiddenCategory' -WorkItemType 'Feedback Request' -WitAdminPath $WitAdminPath
    Add-WorkItemCategoryType -Collection $Collection -Project $Project -ReferenceName 'Microsoft.HiddenCategory' -WorkItemType 'Feedback Response' -WitAdminPath $WitAdminPath
    if (-not $KeepBugInRequirementCategory) {
        Remove-WorkItemCategoryType -Collection $Collection -Project $Project -ReferenceName 'Microsoft.RequirementCategory' -WorkItemType 'Bug' -WitAdminPath $WitAdminPath
    }
}
