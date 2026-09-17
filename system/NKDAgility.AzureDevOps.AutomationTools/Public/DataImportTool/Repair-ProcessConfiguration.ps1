function Repair-ProcessConfiguration {
    <#
    .SYNOPSIS
    Exports a project's ProjectProcessConfiguration, repairs it to Data Import Tool
    requirements (TypeFields, backlog categories/names/states/columns, feedback work
    items), and imports it back.

    .DESCRIPTION
    Wraps the full export -> edit -> import sequence that otherwise takes ~40 runbook
    lines per project. The state mappings default to an Agile-derived set; they MUST match
    the actual workflow states of the project's work item types or witadmin will reject
    the import - check with Get-WitWorkItemTypeState first and override -RequirementStates /
    -TaskStates where they differ.

    Run Install-FeedbackWorkItemTypes for the project first: the feedback categories
    referenced here must already exist.

    Use -SkipImport to stop after editing the local XML so it can be reviewed before
    pushing it back with Import-WitProcessConfigurationFixFile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$Path,
        [hashtable[]]$RequirementStates = @(
            @{ Type = 'Proposed'; Value = 'Proposed' }
            @{ Type = 'InProgress'; Value = 'Resolved' }
            @{ Type = 'InProgress'; Value = 'Active' }
            @{ Type = 'InProgress'; Value = 'QAReview' }
            @{ Type = 'Complete'; Value = 'Closed' }
            @{ Type = 'Complete'; Value = 'Inactive' }
        ),
        [hashtable[]]$TaskStates = @(
            @{ Type = 'Proposed'; Value = 'Pending' }
            @{ Type = 'InProgress'; Value = 'Active' }
            @{ Type = 'Complete'; Value = 'Closed' }
            @{ Type = 'Complete'; Value = 'Cancelled' }
        ),
        [string]$RequirementSingularName = 'User Story',
        [string]$RequirementPluralName = 'User Stories',
        [string]$EffortReferenceName = 'Microsoft.VSTS.Scheduling.StoryPoints',
        [switch]$SkipImport,
        [string]$WitAdminPath
    )

    Write-FixStep "Repairing process configuration for '$Project' via '$Path'"
    Export-WitProcessConfigurationFixFile -Collection $Collection -Project $Project -Path $Path -WitAdminPath $WitAdminPath

    # TypeFields (refnames taken from the OOB Agile template)
    Add-ProcessConfigurationElement -Path $Path -ParentXPath '/ProjectProcessConfiguration' -ElementName 'TypeFields'
    Add-ProcessConfigurationTypeField -Path $Path -Type 'Team' -ReferenceName 'System.AreaPath'
    Add-ProcessConfigurationTypeField -Path $Path -Type 'RemainingWork' -ReferenceName 'Microsoft.VSTS.Scheduling.RemainingWork' -Format '{0} h'
    Add-ProcessConfigurationTypeField -Path $Path -Type 'Order' -ReferenceName 'Microsoft.VSTS.Common.StackRank'
    Add-ProcessConfigurationTypeField -Path $Path -Type 'Effort' -ReferenceName $EffortReferenceName
    Add-ProcessConfigurationTypeField -Path $Path -Type 'Activity' -ReferenceName 'Microsoft.VSTS.Common.Activity'
    Add-ProcessConfigurationTypeField -Path $Path -Type 'ApplicationStartInformation' -ReferenceName 'Microsoft.VSTS.Feedback.ApplicationStartInformation'
    Add-ProcessConfigurationTypeField -Path $Path -Type 'ApplicationLaunchInstructions' -ReferenceName 'Microsoft.VSTS.Feedback.ApplicationLaunchInstructions'
    Add-ProcessConfigurationTypeField -Path $Path -Type 'ApplicationType' -ReferenceName 'Microsoft.VSTS.Feedback.ApplicationType' -Values @(
        @{ Type = 'ClientApp'; Value = 'Client application' }
        @{ Type = 'RemoteMachine'; Value = 'Remote machine' }
        @{ Type = 'WebApp'; Value = 'Web application' }
    )

    # RequirementBacklog (category, names, states, columns, add panel)
    Set-ProcessConfigurationAttribute -Path $Path -XPath '/ProjectProcessConfiguration/RequirementBacklog' -AttributeName 'category' -Value 'Microsoft.RequirementCategory'
    Set-ProcessConfigurationAttribute -Path $Path -XPath '/ProjectProcessConfiguration/RequirementBacklog' -AttributeName 'pluralName' -Value $RequirementPluralName
    Set-ProcessConfigurationAttribute -Path $Path -XPath '/ProjectProcessConfiguration/RequirementBacklog' -AttributeName 'singularName' -Value $RequirementSingularName
    Set-ProcessConfigurationStates -Path $Path -BacklogElement 'RequirementBacklog' -States $RequirementStates
    Set-ProcessConfigurationColumns -Path $Path -BacklogElement 'RequirementBacklog' -Columns @(
        @{ ReferenceName = 'System.WorkItemType'; Width = 100 }
        @{ ReferenceName = 'System.Title'; Width = 400 }
        @{ ReferenceName = 'System.State'; Width = 100 }
        @{ ReferenceName = $EffortReferenceName; Width = 50 }
    )
    Set-ProcessConfigurationAddPanel -Path $Path -BacklogElement 'RequirementBacklog' -Fields @('System.Title')

    # TaskBacklog (category, names, states, columns, add panel)
    Set-ProcessConfigurationAttribute -Path $Path -XPath '/ProjectProcessConfiguration/TaskBacklog' -AttributeName 'category' -Value 'Microsoft.TaskCategory'
    Set-ProcessConfigurationAttribute -Path $Path -XPath '/ProjectProcessConfiguration/TaskBacklog' -AttributeName 'pluralName' -Value 'Tasks'
    Set-ProcessConfigurationAttribute -Path $Path -XPath '/ProjectProcessConfiguration/TaskBacklog' -AttributeName 'singularName' -Value 'Task'
    Set-ProcessConfigurationStates -Path $Path -BacklogElement 'TaskBacklog' -States $TaskStates
    Set-ProcessConfigurationColumns -Path $Path -BacklogElement 'TaskBacklog' -Columns @(
        @{ ReferenceName = 'System.WorkItemType'; Width = 100 }
        @{ ReferenceName = 'System.Title'; Width = 400 }
        @{ ReferenceName = 'System.State'; Width = 100 }
        @{ ReferenceName = 'Microsoft.VSTS.Scheduling.RemainingWork'; Width = 50 }
    )
    Set-ProcessConfigurationAddPanel -Path $Path -BacklogElement 'TaskBacklog' -Fields @('System.Title')

    # Feedback work items (states taken from the OOB Agile template)
    Add-ProcessConfigurationElement -Path $Path -ParentXPath '/ProjectProcessConfiguration' -ElementName 'FeedbackRequestWorkItems'
    Set-ProcessConfigurationAttribute -Path $Path -XPath '/ProjectProcessConfiguration/FeedbackRequestWorkItems' -AttributeName 'category' -Value 'Microsoft.FeedbackRequestCategory'
    Set-ProcessConfigurationAttribute -Path $Path -XPath '/ProjectProcessConfiguration/FeedbackRequestWorkItems' -AttributeName 'pluralName' -Value 'Feedback Requests'
    Set-ProcessConfigurationAttribute -Path $Path -XPath '/ProjectProcessConfiguration/FeedbackRequestWorkItems' -AttributeName 'singularName' -Value 'Feedback Request'
    Set-ProcessConfigurationStates -Path $Path -BacklogElement 'FeedbackRequestWorkItems' -States @(
        @{ Type = 'InProgress'; Value = 'Active' }
        @{ Type = 'Complete'; Value = 'Closed' }
    )
    Add-ProcessConfigurationElement -Path $Path -ParentXPath '/ProjectProcessConfiguration' -ElementName 'FeedbackResponseWorkItems'
    Set-ProcessConfigurationAttribute -Path $Path -XPath '/ProjectProcessConfiguration/FeedbackResponseWorkItems' -AttributeName 'category' -Value 'Microsoft.FeedbackResponseCategory'
    Set-ProcessConfigurationAttribute -Path $Path -XPath '/ProjectProcessConfiguration/FeedbackResponseWorkItems' -AttributeName 'pluralName' -Value 'Feedback Responses'
    Set-ProcessConfigurationAttribute -Path $Path -XPath '/ProjectProcessConfiguration/FeedbackResponseWorkItems' -AttributeName 'singularName' -Value 'Feedback Response'
    Set-ProcessConfigurationStates -Path $Path -BacklogElement 'FeedbackResponseWorkItems' -States @(
        @{ Type = 'InProgress'; Value = 'Active' }
        @{ Type = 'Complete'; Value = 'Closed' }
    )

    if ($SkipImport) {
        Write-FixStep "SkipImport set - review '$Path' then run Import-WitProcessConfigurationFixFile to apply it"
        return
    }
    Import-WitProcessConfigurationFixFile -Collection $Collection -Project $Project -Path $Path -WitAdminPath $WitAdminPath

    # Verify the server retained the repair rather than silently discarding
    # elements: re-export and check the pieces this function is responsible for.
    $verifyFile = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).ProcessConfig.xml"
    try {
        Export-WitProcessConfigurationFixFile -Collection $Collection -Project $Project -Path $verifyFile -WitAdminPath $WitAdminPath
        $verify = [xml](Get-Content -LiteralPath $verifyFile -Raw)
        $missing = @(
            if (-not $verify.SelectSingleNode('/ProjectProcessConfiguration/TypeFields/TypeField')) { 'TypeFields' }
            if (-not $verify.SelectSingleNode("/ProjectProcessConfiguration/RequirementBacklog[@category='Microsoft.RequirementCategory']")) { 'RequirementBacklog@category' }
            if (-not $verify.SelectSingleNode("/ProjectProcessConfiguration/TaskBacklog[@category='Microsoft.TaskCategory']")) { 'TaskBacklog@category' }
            if (-not $verify.SelectSingleNode('/ProjectProcessConfiguration/FeedbackRequestWorkItems/States/State')) { 'FeedbackRequestWorkItems' }
            if (-not $verify.SelectSingleNode('/ProjectProcessConfiguration/FeedbackResponseWorkItems/States/State')) { 'FeedbackResponseWorkItems' }
        )
        if ($missing) {
            throw "Verification failed: after import, '$Project' is still missing: $($missing -join ', ')."
        }
        Write-FixStep "  verified: re-export retains TypeFields, backlog categories and feedback elements"
    }
    finally {
        Remove-Item -LiteralPath $verifyFile -Force -ErrorAction SilentlyContinue
    }
}
