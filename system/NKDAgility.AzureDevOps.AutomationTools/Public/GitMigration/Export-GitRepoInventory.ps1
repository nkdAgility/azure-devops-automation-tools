function Export-GitRepoInventory {
    <#
    .SYNOPSIS
    Builds or refreshes the repository inventory/approval CSV for an Azure DevOps to
    GitHub migration.

    .DESCRIPTION
    Enumerates every project in the source organisation and every git repository in each
    project, and merges the result into the CSV at -Path. The CSV is the approval record
    the engagement runs on: the customer marks repositories Approved (and may edit the
    pre-filled TargetName) and Migrate-ReposToGitHub.ps1 migrates exactly the approved
    rows.

    Merge rules, keyed by SourceRepoId so renames on either side never duplicate a row:
      - Customer-owned columns (TargetName, Approved, Notes) on existing rows are
        preserved verbatim.
      - Fact columns (SourceProject, SourceRepo, DefaultBranch, SizeMB, IsDisabled,
        WebUrl, Status) are refreshed from the source on every run.
      - Rows whose repository has vanished from the source are kept as evidence and
        marked Status = MissingFromSource.
      - New repositories get a pre-filled TargetName: the slugified repository name, or
        the project-prefixed slug when that name is already claimed by another row (or,
        when -GitHubOrg is supplied, by an existing GitHub repository no row claims).

    Disabled repositories always have their existing rows refreshed, but only appear as
    NEW rows when -IncludeDisabled is passed - they cannot be cloned, so by default they
    do not enter the approval list.

    .PARAMETER Collection
    Source organisation URL, used verbatim (https://dev.azure.com/<org> or
    https://<org>.visualstudio.com).

    .PARAMETER Path
    Path of the inventory CSV to create or merge into. Commit this file: it is the
    engagement's approval record.

    .PARAMETER Pat
    Personal access token for the source organisation (Code Read). Omit to authenticate
    via Entra - the default across the module.

    .PARAMETER GitHubOrg
    Optional GitHub organisation to collision-check new TargetNames against, so a
    pre-filled name never silently collides with a repository that already exists there.

    .PARAMETER GitHubToken
    GitHub token for -GitHubOrg. Omit to use the signed-in gh CLI, then GITHUB_TOKEN
    (see Get-GitHubAccessToken).

    .PARAMETER IncludeDisabled
    Add rows for disabled source repositories too.

    .PARAMETER PassThru
    Also return the merged rows.

    .EXAMPLE
    Export-GitRepoInventory -Collection https://compucal.visualstudio.com -Pat $pat `
        -GitHubOrg 'CompuCal-Solutions' -GitHubToken $env:GITHUB_TOKEN `
        -Path .\repo-inventory.csv
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Path,
        [string]$Pat,
        [string]$GitHubOrg,
        [string]$GitHubToken,
        [switch]$IncludeDisabled,
        [switch]$PassThru,

        [switch]$UseDefaultCredentials
    )

    $columns = @('SourceProject', 'SourceRepo', 'SourceRepoId', 'DefaultBranch', 'SizeMB',
        'IsDisabled', 'WebUrl', 'Status', 'TargetName', 'Approved', 'Notes')

    # Existing rows, keyed by repo id. Rows are rebuilt with the full column set so an
    # inventory produced by an older version gains new columns without losing data.
    $rowsById = [ordered]@{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($row in @(Import-Csv -LiteralPath $Path)) {
            if (-not ($row.PSObject.Properties['SourceRepoId'] -and $row.SourceRepoId)) { continue }
            $rebuilt = [ordered]@{}
            foreach ($column in $columns) {
                $rebuilt[$column] = if ($row.PSObject.Properties[$column]) { [string]$row.$column } else { '' }
            }
            $rowsById[[string]$row.SourceRepoId] = [pscustomobject]$rebuilt
        }
    }

    # Every name already claimed by a row is taken, case-insensitively - GitHub treats
    # 'Repo' and 'repo' as the same repository name.
    $claimedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $rowsById.Values) {
        if ($row.TargetName) { [void]$claimedNames.Add($row.TargetName) }
    }

    # Repositories that already exist in the GitHub org and are NOT claimed by a row
    # also block a pre-filled name: creating over them would land a migration in
    # somebody else's repository.
    if ($GitHubOrg) {
        foreach ($ghRepo in @(Get-GitHubRepository -Org $GitHubOrg -Token $GitHubToken)) {
            if ($ghRepo -and $ghRepo.name -and -not $claimedNames.Contains($ghRepo.name)) {
                [void]$claimedNames.Add($ghRepo.name)
            }
        }
    }

    $seenIds = [System.Collections.Generic.HashSet[string]]::new()
    $newRows = 0

    Write-InfoLog "Enumerating projects in {collection}" -PropertyValues $Collection
    $projects = @(Get-TeamProject -Collection $Collection -Pat $Pat -UseDefaultCredentials:$UseDefaultCredentials)
    Write-Host ("==> {0} project(s) found in {1}" -f $projects.Count, $Collection) -ForegroundColor Cyan

    foreach ($project in $projects) {
        $repos = @(Get-GitRepository -Collection $Collection -Project $project.name -Pat $Pat `
                -UseDefaultCredentials:$UseDefaultCredentials -IncludeDisabled)
        Write-Host ("    {0}: {1} repo(s)" -f $project.name, $repos.Count) -ForegroundColor DarkGray

        foreach ($repo in $repos) {
            $id = [string]$repo.id
            [void]$seenIds.Add($id)

            $isDisabled = [bool]($repo.PSObject.Properties['isDisabled'] -and $repo.isDisabled)
            $defaultBranch = if ($repo.PSObject.Properties['defaultBranch']) { [string]$repo.defaultBranch } else { '' }
            $sizeMB = if ($repo.PSObject.Properties['size'] -and $repo.size) { [math]::Round([int64]$repo.size / 1MB, 2) } else { 0 }
            $webUrl = if ($repo.PSObject.Properties['webUrl']) { [string]$repo.webUrl } else { '' }
            $status = if ($isDisabled) { 'Disabled' } else { 'Active' }

            if ($rowsById.Contains($id)) {
                # Refresh the facts; never touch the customer-owned columns.
                $row = $rowsById[$id]
                $row.SourceProject = $project.name
                $row.SourceRepo = $repo.name
                $row.DefaultBranch = $defaultBranch
                $row.SizeMB = $sizeMB
                $row.IsDisabled = $isDisabled
                $row.WebUrl = $webUrl
                $row.Status = $status
                continue
            }

            if ($isDisabled -and -not $IncludeDisabled) { continue }

            # Pre-fill a collision-free TargetName: the repo slug, then the
            # project-prefixed slug, then a numeric suffix as a last resort.
            $targetName = ConvertTo-GitHubRepoName -Name $repo.name
            if ($claimedNames.Contains($targetName)) {
                $targetName = ConvertTo-GitHubRepoName -Name ('{0}-{1}' -f $project.name, $repo.name)
            }
            $suffix = 1
            $candidate = $targetName
            while ($claimedNames.Contains($candidate)) {
                $suffix++
                $candidate = '{0}-{1}' -f $targetName, $suffix
            }
            $targetName = $candidate
            [void]$claimedNames.Add($targetName)

            $rowsById[$id] = [pscustomobject][ordered]@{
                SourceProject = $project.name
                SourceRepo    = $repo.name
                SourceRepoId  = $id
                DefaultBranch = $defaultBranch
                SizeMB        = $sizeMB
                IsDisabled    = $isDisabled
                WebUrl        = $webUrl
                Status        = $status
                TargetName    = $targetName
                Approved      = ''
                Notes         = ''
            }
            $newRows++
        }
    }

    # Rows whose repository no longer answers on the source: evidence, not deletions.
    $missing = 0
    foreach ($row in $rowsById.Values) {
        if (-not $seenIds.Contains([string]$row.SourceRepoId)) {
            $row.Status = 'MissingFromSource'
            $missing++
        }
    }

    $rows = @($rowsById.Values)
    $approved = @($rows | Where-Object { $_.Approved -match '^(?i)(y|yes|true|1)$' }).Count

    if ($PSCmdlet.ShouldProcess($Path, 'Write repository inventory CSV')) {
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $rows | Select-Object $columns | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
        Write-FixStep ("Inventory written: {0} - {1} repo(s) total, {2} new, {3} approved, {4} missing from source" -f `
                $Path, $rows.Count, $newRows, $approved, $missing)
    }

    if ($PassThru) { return $rows }
}
