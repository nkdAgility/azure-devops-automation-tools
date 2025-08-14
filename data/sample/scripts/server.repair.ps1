

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



