# This repo is the toolkit, not a workspace. It no longer holds customer data,
# a data\ folder, or a config.json, and nothing should be run from here.
#
# runmefirst.ps1 used to set up a local data\<environment>\ folder in this repo.
# That model is gone: every engagement now lives in its own client workspace
# repo, which keeps the customer's organisations, secrets, migrations and
# exports together and under the client's own source control.

Write-Host @'

  This repo is the toolkit - engagements run from a client workspace repo.

  To create or update a client workspace, run this from the root of the
  client repo (an empty folder is fine):

      irm https://raw.githubusercontent.com/nkdAgility/azure-devops-automation-tools/main/bootstrap.ps1 | iex

  Then, in that client repo:

      . .\init.ps1
      New-Migration -Name <Name> -Type DataImport|MigrationTools|MigrationPlatform

  Client workspaces found on this machine:

'@ -ForegroundColor Cyan

$reposRoot = Join-Path $env:USERPROFILE 'source\repos'
$workspaces = @(Get-ChildItem -Path $reposRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'workspace.json') })

if ($workspaces) {
    $workspaces | ForEach-Object { Write-Host "      $($_.FullName)" -ForegroundColor Green }
}
else {
    Write-Host "      (none found under $reposRoot)" -ForegroundColor DarkGray
}
Write-Host ''
