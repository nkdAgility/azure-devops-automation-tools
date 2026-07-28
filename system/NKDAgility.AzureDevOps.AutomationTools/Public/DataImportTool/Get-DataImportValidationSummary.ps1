function Get-DataImportValidationSummary {
    <#
    .SYNOPSIS
    Parses a Data Import Tool validation run's ProjectProcessesMap.log into per-project
    error counts and per-error-code counts, so before/after fix runs can be compared.

    .PARAMETER Path
    Either a specific run folder (containing ProjectProcessesMap.log) or a parent folder
    of timestamped runs (e.g. ...\Logs\MyCollection), in which case the newest run is used.

    .EXAMPLE
    Get-DataImportValidationSummary -Path '.\data\debug\DataImportTools\output\Logs\MyCollection'

    .EXAMPLE
    $before = Get-DataImportValidationSummary -Path $logs
    # ...run fixes, re-run Migrator Prepare/Validate...
    $after = Get-DataImportValidationSummary -Path $logs
    Compare-Object $before.Projects $after.Projects -Property Project, Errors
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    $runFolder = $Path
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'ProjectProcessesMap.log') -PathType Leaf)) {
        $latest = Get-ChildItem -LiteralPath $Path -Directory -ErrorAction Stop |
            Where-Object { $_.Name -match '^\d{8}_\d{6}$' } |
            Sort-Object Name |
            Select-Object -Last 1
        if (-not $latest) { throw "No ProjectProcessesMap.log or timestamped run folders found under '$Path'." }
        $runFolder = $latest.FullName
    }
    $log = Join-Path $runFolder 'ProjectProcessesMap.log'
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw "'$log' was not found." }
    $content = Get-Content -LiteralPath $log -Raw

    $projects = [regex]::Matches($content, 'for project (.+?) with (\d+) errors') | ForEach-Object {
        [pscustomobject]@{ Project = $_.Groups[1].Value; Errors = [int]$_.Groups[2].Value }
    }
    $codes = [regex]::Matches($content, '\b(TF\d{6}|VS\d{6})\b') |
        Group-Object { $_.Groups[1].Value } |
        ForEach-Object { [pscustomobject]@{ Code = $_.Name; Count = $_.Count } } |
        Sort-Object Count -Descending

    [pscustomobject]@{
        Run         = Split-Path $runFolder -Leaf
        Path        = $runFolder
        TotalErrors = [int](($projects | Measure-Object -Property Errors -Sum).Sum)
        Projects    = @($projects | Sort-Object Errors -Descending)
        ErrorCodes  = @($codes)
    }
}
