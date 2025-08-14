

# Resolve witadmin.exe path dynamically and store in a variable
# Order of resolution:
# 1. On PATH
# 2. vswhere (latest VS with Team Explorer component)
# 3. Search typical Visual Studio install folders

$witAdmin = $null

try {
	$cmd = Get-Command witadmin.exe -ErrorAction SilentlyContinue
	if ($cmd) { $witAdmin = $cmd.Source }
} catch {}

if (-not $witAdmin) {
	$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
	if (Test-Path $vswhere) {
		$found = & $vswhere -latest -prerelease -requires Microsoft.VisualStudio.TeamExplorer -find **\witadmin.exe
		if ($found) { $witAdmin = $found }
	}
}

if (-not $witAdmin) {
	$searchRoot = "${env:ProgramFiles(x86)}\Microsoft Visual Studio"
	if (Test-Path $searchRoot) {
		$match = Get-ChildItem -Path $searchRoot -Filter witadmin.exe -Recurse -ErrorAction SilentlyContinue |
			Sort-Object LastWriteTime -Descending |
			Select-Object -First 1
		if ($match) { $witAdmin = $match.FullName }
	}
}

if (-not $witAdmin) { throw 'witadmin.exe not found. Install Visual Studio Team Explorer components or add witadmin.exe to PATH.' }

Write-Host "Using witadmin: $witAdmin" -ForegroundColor Cyan

## Fixes for Fields

& $witAdmin changefield /collection:http://sdfsddfsdg:8080/tfs/asdsadsad /n:ROMS.StartDate /name:"Start Date (moo)" /noprompt

## Project Updates
## Ensure process-customization-scripts repo is present (clone or update)
$repoUrl   = 'https://github.com/microsoft/process-customization-scripts.git'
$repoName  = 'process-customization-scripts'
$targetRoot = Join-Path $env:USERPROFILE 'source\repos'
$repoPath  = Join-Path $targetRoot $repoName

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
	throw 'git is required but was not found on PATH.'
}

if (-not (Test-Path $targetRoot)) {
	Write-Host "Creating repos root: $targetRoot" -ForegroundColor DarkCyan
	New-Item -ItemType Directory -Path $targetRoot | Out-Null
}

if (Test-Path (Join-Path $repoPath '.git')) {
	Write-Host "Updating existing repo at $repoPath" -ForegroundColor Cyan
	git -C $repoPath fetch --all --prune 2>&1 | Write-Verbose
	git -C $repoPath pull --ff-only 2>&1 | Write-Verbose
} else {
	Write-Host "Cloning $repoUrl to $repoPath" -ForegroundColor Cyan
	git clone $repoUrl $repoPath | Write-Verbose
}

if (-not (Test-Path (Join-Path $repoPath '.git'))) {
	throw "Failed to ensure repository at $repoPath"
}

Write-Host "Repo ready: $repoPath" -ForegroundColor Green

# Example: dot-source helper scripts from the cloned repo (uncomment/adjust as needed)
# . (Join-Path $repoPath 'scripts' 'import.ps1')
# . (Join-Path $repoPath 'scripts' 'conform.ps1')

# TODO: Add calls to import / conform scripts as required




