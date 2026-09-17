BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $engine = Join-Path $repoRoot 'system/NKDAgility.AzureDevOps.AutomationTools/Engines/Publish-PipelineArtifacts.ps1'
    $testRoot = Join-Path $repoRoot 'output/publish-engine-tests'
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $inventoryPath = Join-Path $testRoot 'inventory.csv'
    $planPath = Join-Path $testRoot 'plan.csv'
    $workPath = Join-Path $testRoot 'staged'
    $common = @{
        InventoryPath = $inventoryPath
        PlanPath = $planPath
        WorkPath = $workPath
        SourceOrg = 'https://dev.azure.com/source'
        SourceProject = 'SourceProject'
        TargetOrg = 'https://dev.azure.com/target'
        TargetProject = 'TargetProject'
        FeedMappings = @([pscustomobject]@{ ProductPattern = '*'; Feed = 'TargetFeed' })
    }
    function New-InventoryRow {
        param([string]$Version, [int]$BuildId, [string]$Product = 'UM.DB.Opc')
        [pscustomobject]@{
            Location = 'BuildArtifact'; Status = 'File'; RunId = [string]$BuildId
            Artifact = 'drop'; Path = "drop/$Product.$Version.zip"
            FileName = "$Product.$Version.zip"; Product = $Product
            Version = $Version; Format = 'zip'; Bytes = '3'; Branch = 'refs/heads/main'
        }
    }
    function Resolve-AzureDevOpsAuth {
        [pscustomobject]@{ Mode = 'PAT'; Headers = @{ Authorization = 'Basic fixture' }; Token = 'fixture' }
    }
    function az {
        $global:publishCallCount++
        $pathIndex = [Array]::IndexOf($args, '--path')
        $global:publishedFiles = @(Get-ChildItem -LiteralPath $args[$pathIndex + 1] -File | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Bytes = ([IO.File]::ReadAllBytes($_.FullName) -join ',') }
        })
        $global:LASTEXITCODE = 0
    }
}

AfterAll {
    $full = [IO.Path]::GetFullPath($testRoot)
    if (-not $full.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected test cleanup path: $full"
    }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}

Describe 'Publish pipeline artifact plan and transfer' {
    BeforeEach {
        Mock Invoke-RestMethod {
            if ($Uri -like 'https://feeds.dev.azure.com/*') { return [pscustomobject]@{ name = 'TargetFeed' } }
            if ($Uri -like 'https://pkgs.dev.azure.com/*') {
                $error = [Exception]::new('Not found')
                $error | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 404 }
                throw $error
            }
            throw "Unexpected request: $Uri"
        }
    }

    It 'selects the latest revision separately for production and each prerelease label' {
        @(
            (New-InventoryRow '2.13.0.3' 100)
            (New-InventoryRow '2.13.0.4' 101)
            (New-InventoryRow '2.13.0.5-beta' 102)
            (New-InventoryRow '2.13.0.6-beta' 103)
            (New-InventoryRow '2.13.0' 99)
        ) | Export-Csv -LiteralPath $inventoryPath -NoTypeInformation

        & $engine @common -WhatIf
        $plan = @(Import-Csv -LiteralPath $planPath)
        @($plan | Where-Object Status -eq 'Ready').Count | Should -Be 2
        ($plan | Where-Object SourceVersion -eq '2.13.0.4').PackageVersion | Should -Be '2.13.0'
        ($plan | Where-Object SourceVersion -eq '2.13.0.4').Status | Should -Be 'Ready'
        ($plan | Where-Object SourceVersion -eq '2.13.0.5-beta').Status | Should -Be 'SupersededByRevision'
        ($plan | Where-Object SourceVersion -eq '2.13.0.6-beta').PackageVersion | Should -Be '2.13.0-beta'
        ($plan | Where-Object SourceVersion -eq '2.13.0.6-beta').Status | Should -Be 'Ready'
    }

    It 'marks existing target versions in the plan and skips them' {
        (New-InventoryRow '2.13.0.4' 101) | Export-Csv -LiteralPath $inventoryPath -NoTypeInformation
        $global:publishCallCount = 0
        Mock Invoke-RestMethod {
            if ($Uri -like 'https://feeds.dev.azure.com/*') { return [pscustomobject]@{ name = 'TargetFeed' } }
            if ($Uri -like 'https://pkgs.dev.azure.com/*') { return [pscustomobject]@{ version = '2.13.0' } }
            throw "Unexpected source request: $Uri"
        }
        Mock Invoke-WebRequest { throw 'Download must not run before target preflight.' }

        & $engine @common -Publish
        (Import-Csv -LiteralPath $planPath)[0].Status | Should -Be 'AlreadyPublished'
        Should -Invoke Invoke-WebRequest -Times 0
        $global:publishCallCount | Should -Be 0
        (Test-Path -LiteralPath $workPath) | Should -BeFalse
    }

    It 'downloads the selected original file and publishes its staging directory' {
        (New-InventoryRow '2.13.0.4' 101) | Export-Csv -LiteralPath $inventoryPath -NoTypeInformation
        $global:publishCallCount = 0
        Mock Invoke-RestMethod {
            if ($Uri -like 'https://feeds.dev.azure.com/*') { return [pscustomobject]@{ name = 'TargetFeed' } }
            if ($Uri -like 'https://pkgs.dev.azure.com/*') {
                $error = [Exception]::new('Not found')
                $error | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 404 }
                throw $error
            }
            if ($Uri -like '*/_apis/build/builds/101/artifacts?*') {
                return [pscustomobject]@{ resource = [pscustomobject]@{ type = 'Container'; data = '#/10/drop' } }
            }
            if ($Uri -like '*/_apis/resources/Containers/10?*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ itemType = 'file'; path = 'drop/UM.DB.Opc.2.13.0.4.zip'; fileId = 55 }) }
            }
            throw "Unexpected request: $Uri"
        }
        Mock Invoke-WebRequest {
            [IO.File]::WriteAllBytes($OutFile, [byte[]]@(65, 66, 67))
        }

        & $engine @common -Publish
        $global:publishCallCount | Should -Be 1
        $global:publishedFiles.Count | Should -Be 1
        $global:publishedFiles[0].Name | Should -Be 'UM.DB.Opc.2.13.0.4.zip'
        $global:publishedFiles[0].Bytes | Should -Be '65,66,67'
        (Import-Csv -LiteralPath $planPath)[0].Status | Should -Be 'Published'
    }

    It 'replans an interrupted run and skips a version published previously' {
        (New-InventoryRow '2.13.0.4' 101) | Export-Csv -LiteralPath $inventoryPath -NoTypeInformation
        $global:publishCallCount = 0
        Mock Invoke-RestMethod {
            if ($Uri -like 'https://feeds.dev.azure.com/*') { return [pscustomobject]@{ name = 'TargetFeed' } }
            if ($Uri -like 'https://pkgs.dev.azure.com/*') {
                if ($global:publishCallCount -gt 0) { return [pscustomobject]@{ version = '2.13.0' } }
                $error = [Exception]::new('Not found')
                $error | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 404 }
                throw $error
            }
            if ($Uri -like '*/_apis/build/builds/101/artifacts?*') {
                return [pscustomobject]@{ resource = [pscustomobject]@{ type = 'Container'; data = '#/10/drop' } }
            }
            if ($Uri -like '*/_apis/resources/Containers/10?*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ itemType = 'file'; path = 'drop/UM.DB.Opc.2.13.0.4.zip'; fileId = 55 }) }
            }
            throw "Unexpected request: $Uri"
        }
        Mock Invoke-WebRequest { [IO.File]::WriteAllBytes($OutFile, [byte[]]@(65, 66, 67)) }

        & $engine @common -Publish
        & $engine @common -Publish

        $global:publishCallCount | Should -Be 1
        (Import-Csv -LiteralPath $planPath)[0].Status | Should -Be 'AlreadyPublished'
    }

    It 'skips a version that appears after planning but before its upload' {
        (New-InventoryRow '2.13.0.4' 101) | Export-Csv -LiteralPath $inventoryPath -NoTypeInformation
        $global:publishCallCount = 0
        $global:versionLookupCount = 0
        Mock Invoke-RestMethod {
            if ($Uri -like 'https://feeds.dev.azure.com/*') { return [pscustomobject]@{ name = 'TargetFeed' } }
            if ($Uri -like 'https://pkgs.dev.azure.com/*') {
                $global:versionLookupCount++
                if ($global:versionLookupCount -gt 1) { return [pscustomobject]@{ version = '2.13.0' } }
                $error = [Exception]::new('Not found')
                $error | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 404 }
                throw $error
            }
            throw "Unexpected request: $Uri"
        }
        Mock Invoke-WebRequest { throw 'An existing version must not be downloaded.' }

        & $engine @common -Publish

        $global:versionLookupCount | Should -Be 2
        $global:publishCallCount | Should -Be 0
        Should -Invoke Invoke-WebRequest -Times 0
        (Import-Csv -LiteralPath $planPath)[0].Status | Should -Be 'AlreadyPublished'
    }

    It 'ignores a staged older revision when publishing a newer selection' {
        $oldStage = Join-Path $workPath 'um.db.opc.zip/2.13.0'
        New-Item -ItemType Directory -Path $oldStage -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $oldStage 'UM.DB.Opc.2.13.0.3.zip'), [byte[]]@(88))
        (New-InventoryRow '2.13.0.4' 101) | Export-Csv -LiteralPath $inventoryPath -NoTypeInformation
        $global:publishCallCount = 0
        Mock Invoke-RestMethod {
            if ($Uri -like 'https://feeds.dev.azure.com/*') { return [pscustomobject]@{ name = 'TargetFeed' } }
            if ($Uri -like 'https://pkgs.dev.azure.com/*') {
                $error = [Exception]::new('Not found')
                $error | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 404 }
                throw $error
            }
            if ($Uri -like '*/_apis/build/builds/101/artifacts?*') { return [pscustomobject]@{ resource = [pscustomobject]@{ type = 'Container'; data = '#/10/drop' } } }
            if ($Uri -like '*/_apis/resources/Containers/10?*') { return [pscustomobject]@{ value = @([pscustomobject]@{ itemType = 'file'; path = 'drop/UM.DB.Opc.2.13.0.4.zip'; fileId = 55 }) } }
            throw "Unexpected request: $Uri"
        }
        Mock Invoke-WebRequest { [IO.File]::WriteAllBytes($OutFile, [byte[]]@(65, 66, 67)) }

        & $engine @common -Publish

        $global:publishCallCount | Should -Be 1
        $global:publishedFiles.Count | Should -Be 1
        $global:publishedFiles[0].Name | Should -Be 'UM.DB.Opc.2.13.0.4.zip'
    }

    It 'skips a version created during the download' {
        (New-InventoryRow '2.13.0.4' 101) | Export-Csv -LiteralPath $inventoryPath -NoTypeInformation
        $global:publishCallCount = 0
        $global:versionLookupCount = 0
        Mock Invoke-RestMethod {
            if ($Uri -like 'https://feeds.dev.azure.com/*') { return [pscustomobject]@{ name = 'TargetFeed' } }
            if ($Uri -like 'https://pkgs.dev.azure.com/*') {
                $global:versionLookupCount++
                if ($global:versionLookupCount -gt 2) { return [pscustomobject]@{ version = '2.13.0' } }
                $error = [Exception]::new('Not found')
                $error | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 404 }
                throw $error
            }
            if ($Uri -like '*/_apis/build/builds/101/artifacts?*') { return [pscustomobject]@{ resource = [pscustomobject]@{ type = 'Container'; data = '#/10/drop' } } }
            if ($Uri -like '*/_apis/resources/Containers/10?*') { return [pscustomobject]@{ value = @([pscustomobject]@{ itemType = 'file'; path = 'drop/UM.DB.Opc.2.13.0.4.zip'; fileId = 55 }) } }
            throw "Unexpected request: $Uri"
        }
        Mock Invoke-WebRequest { [IO.File]::WriteAllBytes($OutFile, [byte[]]@(65, 66, 67)) }

        & $engine @common -Publish

        $global:versionLookupCount | Should -Be 3
        $global:publishCallCount | Should -Be 0
        (Import-Csv -LiteralPath $planPath)[0].Status | Should -Be 'AlreadyPublished'
    }
}
