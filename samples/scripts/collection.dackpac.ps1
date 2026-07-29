<#!
Simple DACPAC publish script.

Purpose: Publish one or more .dacpac files to a target SQL Server / Azure SQL database.

Usage examples:
	# Single dacpac
	pwsh ./collection.dackpac.ps1 -Server "." -Database MyDb -Dacpac .\MyDb.dacpac

	# All dacpacs in a folder (alphabetical order)
	pwsh ./collection.dackpac.ps1 -Server myserver -Database MyDb -Dacpac .\dacpacs -Recurse

Notes:
	- Requires sqlpackage.exe to be installed and either in PATH or supplied via -SqlPackagePath.
	- Uses /Action:Publish only. Keep it simple.
!#>

[CmdletBinding()]
param(
	[Parameter(Mandatory)][string]$Server,
	[Parameter(Mandatory)][string]$Database,
	# Path to a single .dacpac file OR a directory containing .dacpac files
	[Parameter(Mandatory)][string]$Dacpac,
	# Optional explicit path to sqlpackage.exe (if not on PATH)
	[string]$SqlPackagePath,
	# Recurse subfolders when Dacpac is a directory
	[switch]$Recurse,
	# Continue after a failure (otherwise script stops at first error)
	[switch]$ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-SqlPackage {
	param([string]$Provided)
	if ($Provided) {
		if (Test-Path $Provided) { return (Resolve-Path $Provided).Path }
		throw "sqlpackage.exe not found at provided path: $Provided"
	}
	# If it's already on PATH just return the command path
	$cmd = Get-Command sqlpackage -ErrorAction SilentlyContinue
	if ($cmd) { return $cmd.Source }
	throw 'sqlpackage.exe not found. Install Data-Tier App Framework or add to PATH.'
}

function Get-DacpacList {
	param([string]$Path,[switch]$Recurse)
	if (-not (Test-Path $Path)) { throw "Dacpac path not found: $Path" }
	if (Test-Path $Path -PathType Leaf) {
		if ($Path -notmatch '\\.dacpac$') { throw 'Specified file is not a .dacpac' }
		return ,(Resolve-Path $Path).Path
	}
	$opt = @{ Filter = '*.dacpac' }
	if ($Recurse) { $opt.Recurse = $true }
	$files = Get-ChildItem -Path $Path @opt | Sort-Object FullName
	if (-not $files) { throw 'No .dacpac files found in directory.' }
	return $files.FullName
}

$sqlpackage = Find-SqlPackage -Provided $SqlPackagePath
Write-Host "Using sqlpackage: $sqlpackage"

$dacpacs = Get-DacpacList -Path $Dacpac -Recurse:$Recurse
Write-Host "Found $($dacpacs.Count) dacpac file(s)."

$results = @()
foreach ($dp in $dacpacs) {
	Write-Host "Publishing $dp -> $Server/$Database" -ForegroundColor Cyan
	$args = @(
		'/Action:Publish'
		"/SourceFile:$dp"
		"/TargetServerName:$Server"
		"/TargetDatabaseName:$Database"
	)
	& $sqlpackage @args 2>&1 | ForEach-Object { Write-Host $_ }
	$exit = $LASTEXITCODE
	$results += [pscustomobject]@{ Dacpac = $dp; ExitCode = $exit }
	if ($exit -ne 0) {
		Write-Warning "Failed (exit $exit) for $dp"
		if (-not $ContinueOnError) { throw "Stopping due to failure." }
	} else {
		Write-Host "Success" -ForegroundColor Green
	}
}

Write-Host "Summary:" -ForegroundColor Yellow
$results | ForEach-Object { Write-Host ("  {0} => Exit {1}" -f $_.Dacpac,$_.ExitCode) }
return $results
