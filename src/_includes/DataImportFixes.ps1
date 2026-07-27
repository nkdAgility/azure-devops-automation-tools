function Write-FixStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Message)

    Write-Host "[fix] $Message" -ForegroundColor Cyan
}

function Resolve-WitAdminPath {
    [CmdletBinding()]
    param([string]$WitAdminPath)

    if ($WitAdminPath) {
        if (Test-Path -LiteralPath $WitAdminPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $WitAdminPath).Path
        }
        throw "Unable to find witadmin at '$WitAdminPath'."
    }

    $command = Get-Command 'witadmin.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $visualStudioRoot = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio'
    $match = Get-ChildItem -Path $visualStudioRoot -Filter 'witadmin.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($match) {
        return $match.FullName
    }

    throw 'Unable to find witadmin.exe on PATH or under the Visual Studio installation directory.'
}

function Invoke-WitAdminFix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$WitAdminPath
    )

    $executable = Resolve-WitAdminPath -WitAdminPath $WitAdminPath
    Write-FixStep "witadmin $($Arguments -join ' ')"
    & $executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "witadmin failed with exit code $LASTEXITCODE."
    }
}

function Rename-Field {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Collection,

        [Parameter(Mandatory)]
        [string]$ReferenceName,

        [Parameter(Mandatory)]
        [string]$NewName,

        [string]$WitAdminPath
    )

    Write-FixStep "Renaming field '$ReferenceName' to '$NewName' in $Collection"
    Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @(
        'changefield',
        "/collection:$Collection",
        "/n:$ReferenceName",
        "/name:$NewName",
        '/noprompt'
    )
}

function Export-ProcessConfigurationFixFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$Path,
        [string]$WitAdminPath
    )

    Write-FixStep "Exporting process configuration for '$Project' to '$Path'"
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportprocessconfig', "/collection:$Collection", "/p:$Project", "/f:$Path")
}

function Import-ProcessConfigurationFixFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$Path,
        [string]$WitAdminPath
    )

    Write-FixStep "Importing process configuration '$Path' into '$Project'"
    Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importprocessconfig', "/collection:$Collection", "/p:$Project", "/f:$Path")
}

function Update-ProcessConfigurationFixFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [scriptblock]$Mutation
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Process configuration fix file '$Path' does not exist. Export it first." }
    $xml = [xml](Get-Content -LiteralPath $Path -Raw)
    & $Mutation $xml
    $xml.Save($Path)
    Write-FixStep "Saved '$Path'"
}

function Add-ProcessConfigurationElement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$ParentXPath,
        [Parameter(Mandatory)] [string]$ElementName
    )

    Write-FixStep "Ensuring element '$ElementName' exists under '$ParentXPath'"
    Update-ProcessConfigurationFixFile -Path $Path -Mutation {
        param($xml)
        $parent = $xml.SelectSingleNode($ParentXPath)
        if (-not $parent) { throw "Process configuration node '$ParentXPath' was not found." }
        if ($parent.SelectSingleNode($ElementName)) {
            Write-FixStep "  '$ElementName' already present - no change"
        }
        else {
            [void]$parent.AppendChild($xml.CreateElement($ElementName))
            Write-FixStep "  added '$ElementName'"
        }
    }
}

function Set-ProcessConfigurationAttribute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$XPath,
        [Parameter(Mandatory)] [string]$AttributeName,
        [Parameter(Mandatory)] [string]$Value
    )

    Write-FixStep "Setting @$AttributeName='$Value' on '$XPath'"
    Update-ProcessConfigurationFixFile -Path $Path -Mutation {
        param($xml)
        $node = $xml.SelectSingleNode($XPath)
        if (-not $node) { throw "Process configuration node '$XPath' was not found." }
        Write-FixStep "  previous value: '$($node.GetAttribute($AttributeName))'"
        $node.SetAttribute($AttributeName, $Value)
    }
}

function Add-ProcessConfigurationTypeField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Type,
        [Parameter(Mandatory)] [string]$ReferenceName,
        [string]$Format,
        [hashtable[]]$Values
    )

    Write-FixStep "Setting TypeField type='$Type' to refname='$ReferenceName'"
    Update-ProcessConfigurationFixFile -Path $Path -Mutation {
        param($xml)
        $root = $xml.ProjectProcessConfiguration
        $typeFields = $root.SelectSingleNode('TypeFields')
        if (-not $typeFields) {
            $typeFields = $xml.CreateElement('TypeFields')
            [void]$root.PrependChild($typeFields)
            Write-FixStep '  created missing TypeFields element'
        }
        $node = $typeFields.SelectSingleNode("TypeField[@type='$Type']")
        if (-not $node) {
            $node = $xml.CreateElement('TypeField')
            [void]$typeFields.AppendChild($node)
            Write-FixStep "  added TypeField type='$Type'"
        }
        else {
            Write-FixStep "  updating existing TypeField (was refname='$($node.GetAttribute('refname'))')"
        }
        $node.SetAttribute('refname', $ReferenceName)
        $node.SetAttribute('type', $Type)
        if ($Format) {
            Write-FixStep "  setting format='$Format'"
            $node.SetAttribute('format', $Format)
        }
        if ($Values) {
            Write-FixStep "  setting $($Values.Count) TypeFieldValue(s): $(($Values | ForEach-Object { "$($_.Type)=$($_.Value)" }) -join ', ')"
            $existingValues = $node.SelectSingleNode('TypeFieldValues')
            if ($existingValues) { [void]$node.RemoveChild($existingValues) }
            $valuesNode = $xml.CreateElement('TypeFieldValues')
            foreach ($value in $Values) {
                $valueNode = $xml.CreateElement('TypeFieldValue')
                $valueNode.SetAttribute('type', [string]$value.Type)
                $valueNode.SetAttribute('value', [string]$value.Value)
                [void]$valuesNode.AppendChild($valueNode)
            }
            [void]$node.AppendChild($valuesNode)
        }
    }
}

function Set-ProcessConfigurationStates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$BacklogElement,
        [Parameter(Mandatory)] [hashtable[]]$States
    )

    Write-FixStep "Replacing States on '$BacklogElement' with $($States.Count) state(s): $(($States | ForEach-Object { "$($_.Type)=$($_.Value)" }) -join ', ')"
    Update-ProcessConfigurationFixFile -Path $Path -Mutation {
        param($xml)
        $backlog = $xml.ProjectProcessConfiguration.SelectSingleNode($BacklogElement)
        if (-not $backlog) { throw "Process configuration element '$BacklogElement' was not found." }
        $existing = $backlog.SelectSingleNode('States')
        if ($existing) {
            Write-FixStep "  removing $($existing.ChildNodes.Count) existing state(s)"
            [void]$backlog.RemoveChild($existing)
        }
        $statesNode = $xml.CreateElement('States')
        foreach ($state in $States) {
            $stateNode = $xml.CreateElement('State')
            $stateNode.SetAttribute('type', [string]$state.Type)
            $stateNode.SetAttribute('value', [string]$state.Value)
            [void]$statesNode.AppendChild($stateNode)
        }
        [void]$backlog.PrependChild($statesNode)
    }
}

function Set-ProcessConfigurationColumns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$BacklogElement,
        [Parameter(Mandatory)] [hashtable[]]$Columns
    )

    Write-FixStep "Replacing Columns on '$BacklogElement' with $($Columns.Count) column(s): $(($Columns | ForEach-Object { $_.ReferenceName }) -join ', ')"
    Update-ProcessConfigurationFixFile -Path $Path -Mutation {
        param($xml)
        $backlog = $xml.ProjectProcessConfiguration.SelectSingleNode($BacklogElement)
        if (-not $backlog) { throw "Process configuration element '$BacklogElement' was not found." }
        $existing = $backlog.SelectSingleNode('Columns')
        if ($existing) {
            Write-FixStep "  removing $($existing.ChildNodes.Count) existing column(s)"
            [void]$backlog.RemoveChild($existing)
        }
        $columnsNode = $xml.CreateElement('Columns')
        foreach ($column in $Columns) {
            $columnNode = $xml.CreateElement('Column')
            $columnNode.SetAttribute('refname', [string]$column.ReferenceName)
            $columnNode.SetAttribute('width', [string]$column.Width)
            [void]$columnsNode.AppendChild($columnNode)
        }
        [void]$backlog.AppendChild($columnsNode)
    }
}

function Set-ProcessConfigurationAddPanel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$BacklogElement,
        [Parameter(Mandatory)] [string[]]$Fields
    )

    Write-FixStep "Replacing AddPanel on '$BacklogElement' with field(s): $($Fields -join ', ')"
    Update-ProcessConfigurationFixFile -Path $Path -Mutation {
        param($xml)
        $backlog = $xml.ProjectProcessConfiguration.SelectSingleNode($BacklogElement)
        if (-not $backlog) { throw "Process configuration element '$BacklogElement' was not found." }
        $existing = $backlog.SelectSingleNode('AddPanel')
        if ($existing) {
            Write-FixStep '  removing existing AddPanel'
            [void]$backlog.RemoveChild($existing)
        }
        $panel = $xml.CreateElement('AddPanel')
        $fieldsNode = $xml.CreateElement('Fields')
        foreach ($field in $Fields) {
            $fieldNode = $xml.CreateElement('Field')
            $fieldNode.SetAttribute('refname', $field)
            [void]$fieldsNode.AppendChild($fieldNode)
        }
        [void]$panel.AppendChild($fieldsNode)
        [void]$backlog.AppendChild($panel)
    }
}

function Add-WorkItemCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$ReferenceName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$DefaultWorkItemType,
        [string]$WitAdminPath
    )

    Write-FixStep "Ensuring category '$ReferenceName' ('$Name') exists in '$Project' with default type '$DefaultWorkItemType'"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Categories.xml"
    try {
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportcategories', "/collection:$Collection", "/p:$Project", "/f:$file")
        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        $category = $xml.SelectSingleNode("//*[local-name()='CATEGORY'][@refname='$ReferenceName']")
        if ($category) {
            Write-FixStep "  category '$ReferenceName' already exists - no change"
        }
        else {
            Write-FixStep "  category '$ReferenceName' missing - adding it"
            $category = $xml.CreateElement('CATEGORY')
            $category.SetAttribute('refname', $ReferenceName)
            $category.SetAttribute('name', $Name)
            $default = $xml.CreateElement('DEFAULTWORKITEMTYPE')
            $default.SetAttribute('name', $DefaultWorkItemType)
            [void]$category.AppendChild($default)
            [void]$xml.DocumentElement.AppendChild($category)
            $xml.Save($file)
            Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importcategories', "/collection:$Collection", "/p:$Project", "/f:$file")
        }
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Find-WitRuleScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [string]$WitAdminPath
    )

    $executable = Resolve-WitAdminPath -WitAdminPath $WitAdminPath
    Write-FixStep "Listing work item types in '$Project'"
    $types = & $executable listwitd "/collection:$Collection" "/p:$Project"
    if ($LASTEXITCODE -ne 0) { throw "witadmin listwitd failed with exit code $LASTEXITCODE." }

    foreach ($type in ($types | Where-Object { $_ -and $_.Trim() })) {
        $name = $type.Trim()
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Witd.xml"
        try {
            & $executable exportwitd "/collection:$Collection" "/p:$Project" "/n:$name" "/f:$file" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-FixStep "  '$name': export failed with exit code $LASTEXITCODE"
                continue
            }
            $xml = [xml](Get-Content -LiteralPath $file -Raw)
            foreach ($node in $xml.SelectNodes('//*[@for or @not]')) {
                [pscustomobject]@{
                    Project      = $Project
                    WorkItemType = $name
                    Rule         = $node.Name
                    Field        = $node.ParentNode.GetAttribute('refname')
                    For          = $node.GetAttribute('for')
                    Not          = $node.GetAttribute('not')
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-WorkItemType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [string]$WitAdminPath
    )

    $executable = Resolve-WitAdminPath -WitAdminPath $WitAdminPath
    Write-FixStep "Listing work item types in '$Project'"
    $types = & $executable listwitd "/collection:$Collection" "/p:$Project"
    if ($LASTEXITCODE -ne 0) { throw "witadmin listwitd failed with exit code $LASTEXITCODE." }
    $types | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }
}

function Copy-WorkItemType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$SourceProject,
        [Parameter(Mandatory)] [string]$TargetProject,
        [Parameter(Mandatory)] [string]$WorkItemType,
        [string]$WitAdminPath
    )

    Write-FixStep "Copying work item type '$WorkItemType' from '$SourceProject' to '$TargetProject'"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Witd.xml"
    try {
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportwitd', "/collection:$Collection", "/p:$SourceProject", "/n:$WorkItemType", "/f:$file")
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importwitd', "/collection:$Collection", "/p:$TargetProject", "/f:$file")
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Import-WorkItemTypeFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$Path,
        [string]$WitAdminPath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Work item type definition '$Path' does not exist." }
    Write-FixStep "Importing work item type definition '$Path' into '$Project'"
    Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importwitd', "/collection:$Collection", "/p:$Project", "/f:$Path")
}

function Add-WorkItemCategoryType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$ReferenceName,
        [Parameter(Mandatory)] [string]$WorkItemType,
        [string]$WitAdminPath
    )

    Write-FixStep "Adding work item type '$WorkItemType' to category '$ReferenceName' in '$Project'"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Categories.xml"
    try {
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportcategories', "/collection:$Collection", "/p:$Project", "/f:$file")
        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        $category = $xml.SelectSingleNode("//*[local-name()='CATEGORY'][@refname='$ReferenceName']")
        if (-not $category) { throw "Category '$ReferenceName' was not found in '$Project'." }

        $member = $category.SelectSingleNode("*[@name='$WorkItemType']")
        if ($member) {
            Write-FixStep "  '$WorkItemType' is already a member of '$ReferenceName' - no change"
            return
        }
        $node = $xml.CreateElement('WORKITEMTYPE')
        $node.SetAttribute('name', $WorkItemType)
        [void]$category.AppendChild($node)
        $xml.Save($file)
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importcategories', "/collection:$Collection", "/p:$Project", "/f:$file")
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Remove-WorkItemCategoryType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$ReferenceName,
        [Parameter(Mandatory)] [string]$WorkItemType,
        [string]$WitAdminPath
    )

    Write-FixStep "Removing work item type '$WorkItemType' from category '$ReferenceName' in '$Project'"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Categories.xml"
    try {
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportcategories', "/collection:$Collection", "/p:$Project", "/f:$file")
        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        $category = $xml.SelectSingleNode("//*[local-name()='CATEGORY'][@refname='$ReferenceName']")
        if (-not $category) { throw "Category '$ReferenceName' was not found in '$Project'." }

        $default = $category.SelectSingleNode("*[local-name()='DEFAULTWORKITEMTYPE'][@name='$WorkItemType']")
        if ($default) { throw "'$WorkItemType' is the DEFAULTWORKITEMTYPE of '$ReferenceName' and cannot be removed." }

        $node = $category.SelectSingleNode("*[local-name()='WORKITEMTYPE'][@name='$WorkItemType']")
        if (-not $node) {
            Write-FixStep "  '$WorkItemType' is not a member of '$ReferenceName' - no change"
            return
        }
        [void]$category.RemoveChild($node)
        $xml.Save($file)
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importcategories', "/collection:$Collection", "/p:$Project", "/f:$file")
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Find-GlobalWorkflowRuleScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [string]$Project,
        [string]$WitAdminPath
    )

    $scope = if ($Project) { "project '$Project'" } else { 'the collection' }
    Write-FixStep "Scanning the global workflow for $scope"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).GlobalWorkflow.xml"
    try {
        $arguments = @('exportglobalworkflow', "/collection:$Collection")
        if ($Project) { $arguments += "/p:$Project" }
        $arguments += "/f:$file"
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments $arguments

        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        foreach ($node in $xml.SelectNodes('//*[@for or @not]')) {
            [pscustomobject]@{
                Scope = if ($Project) { $Project } else { 'Collection' }
                Rule  = $node.Name
                Field = $node.SelectSingleNode('ancestor::*[@refname]').GetAttribute('refname')
                For   = $node.GetAttribute('for')
                Not   = $node.GetAttribute('not')
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Remove-GlobalWorkflowRuleScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [string]$Project,
        [Parameter(Mandatory)] [ValidateSet('for', 'not', 'both')] [string]$AttributeName,
        [Parameter(Mandatory)] [string]$Identity,
        [string]$WitAdminPath
    )

    $scope = if ($Project) { "project '$Project'" } else { 'the collection' }
    Write-FixStep "Removing global workflow rule scope '$Identity' ($AttributeName) from $scope"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).GlobalWorkflow.xml"
    try {
        $exportArguments = @('exportglobalworkflow', "/collection:$Collection")
        if ($Project) { $exportArguments += "/p:$Project" }
        $exportArguments += "/f:$file"
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments $exportArguments

        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        $attributes = if ($AttributeName -eq 'both') { @('for', 'not') } else { @($AttributeName) }
        $changeCount = 0
        foreach ($attribute in $attributes) {
            $nodes = @($xml.SelectNodes("//*[@$attribute]") | Where-Object { $_.GetAttribute($attribute) -eq $Identity })
            foreach ($node in $nodes) {
                Write-FixStep "  removing @$attribute from <$($node.Name)> under $($node.ParentNode.Name)"
                [void]$node.RemoveAttribute($attribute)
                $changeCount++
            }
        }
        if ($changeCount -eq 0) {
            $scopes = @($xml.SelectNodes('//*[@for or @not]') | ForEach-Object { "<$($_.Name)> for='$($_.GetAttribute('for'))' not='$($_.GetAttribute('not'))'" } | Sort-Object -Unique)
            $detail = if ($scopes) { " Scoped rules present: $($scopes -join '; ')" } else { ' No scoped rules exist in this global workflow.' }
            throw "No matching global workflow rule scope for '$Identity' was found in $scope.$detail"
        }
        Write-FixStep "  removed $changeCount scope attribute(s)"
        $xml.Save($file)

        $importArguments = @('importglobalworkflow', "/collection:$Collection")
        if ($Project) { $importArguments += "/p:$Project" }
        $importArguments += "/f:$file"
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments $importArguments
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Remove-WitRuleScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$WorkItemType,
        [Parameter(Mandatory)] [ValidateSet('for', 'not', 'both')] [string]$AttributeName,
        [Parameter(Mandatory)] [string]$Identity,
        [string]$WitAdminPath
    )

    Write-FixStep "Removing rule scope '$Identity' ($AttributeName) from work item type '$WorkItemType' in '$Project'"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Witd.xml"
    try {
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportwitd', "/collection:$Collection", "/p:$Project", "/n:$WorkItemType", "/f:$file")
        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        $attributes = if ($AttributeName -eq 'both') { @('for', 'not') } else { @($AttributeName) }
        $changeCount = 0
        foreach ($attribute in $attributes) {
            $nodes = @($xml.SelectNodes("//*[@$attribute]") | Where-Object { $_.GetAttribute($attribute) -eq $Identity })
            foreach ($node in $nodes) {
                Write-FixStep "  removing @$attribute from <$($node.Name)> under $($node.ParentNode.Name)"
                [void]$node.RemoveAttribute($attribute)
                $changeCount++
            }
        }
        if ($changeCount -eq 0) {
            $scopes = @($xml.SelectNodes('//*[@for or @not]') | ForEach-Object { "<$($_.Name)> for='$($_.GetAttribute('for'))' not='$($_.GetAttribute('not'))'" } | Sort-Object -Unique)
            $detail = if ($scopes) { " Scoped rules present: $($scopes -join '; ')" } else { ' No scoped rules exist in this work item type.' }
            throw "No matching rule scope for '$Identity' was found in '$WorkItemType'.$detail"
        }
        Write-FixStep "  removed $changeCount scope attribute(s)"
        $xml.Save($file)
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importwitd', "/collection:$Collection", "/p:$Project", "/f:$file")
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
