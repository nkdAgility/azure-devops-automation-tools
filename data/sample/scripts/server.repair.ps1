

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


# Export the Product Backlog Item work item type definition

$xmlPath = "data\ncsbn\scripts\ProductBacklogItem.xml"
& $witAdmin exportwitd /collection:http://tfsa1uatvm01:8080/tfs/asdsadsad /P:Moo /n:"Product Backlog Item" /f:$xmlPath

Write-Host ''
Write-Host '==================== ACTION REQUIRED ====================' -ForegroundColor Yellow
Write-Host "Edit the exported work item type definition now: $xmlPath" -ForegroundColor Yellow
Write-Host 'Make your changes (e.g., add/modify fields) and save the file.' -ForegroundColor Yellow
Write-Host 'When you are finished,' -ForegroundColor Yellow
Write-Host 'press Enter here to continue with the import...' -ForegroundColor Yellow
Write-Host '==========================================================' -ForegroundColor Yellow
Read-Host 'Press Enter to import once you have edited and saved the file'
& $witAdmin importwitd /collection:http://tfsa1uatvm01:8080/tfs/asdsadsad /P:Moo /f:$xmlPath