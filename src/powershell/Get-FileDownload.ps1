<#!
Minimal file downloader.
Always downloads into a directory (default: current user's Downloads).

Usage:
	./Get-FileDownload.ps1                            # uses default URL -> %USERPROFILE%\Downloads
	./Get-FileDownload.ps1 -Url <url>                 # custom URL -> Downloads
	./Get-FileDownload.ps1 -Url <url> -OutDir c:\temp # custom directory

Parameters:
	-Url     Optional; defaults to pre-set long SQL Server ISO link.
	-OutDir  Target directory (auto-created). Default: $env:USERPROFILE\Downloads
	-Force   Overwrite if file exists.
#>
param(
	[string]$Url = 'https://myvs.download.prss.microsoft.com/dbazure/en_sql_server_2016_developer_x64_dvd_8777069.iso?t=f121b9dc-c5bf-4439-a03c-1fd2a483d6e3&P1=1755129566&P2=601&P3=2&P4=mlHR%2fY8gslBf5DxymedmmemDZD43lwaMaNWM36OjVNjxKawmQspq2Q5uKOmulIAyekNITTT%2bNqLEP8tIsSyFn6LU2XJOcFsCRQt4kSoEUN%2bwqiMPtq9%2fyvyinKKAXRVCl%2b0xNqMTfMtKm%2fsiHaUKV5%2f2e%2b4OUPOgh%2b1CODmizSEGrxHRQVnVrwKr%2bwquUOuAYjOTJ3huyRFd199CUJ2HBF1OkIOAW0i%2bdGToM%2bTvT2I48nuKq6vaeUgHqGUXqzHvWGatwhGuyU30g05D2kmYOc0c%2b7NS7%2bCgPl%2fC0wOUrAAs9bsLZcdkUFb%2fOx1DVlhB85LmNm%2fmHS4hDW2mt61oDw%3d%3d&su=1',
	[string]$OutDir = [IO.Path]::Combine($env:USERPROFILE, 'Downloads'),
	[switch]$Force
)

if(-not $Url) { throw 'No URL specified.' }

if(-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$fileName = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
if(-not $fileName) { $fileName = 'download.bin' }
$OutFile = Join-Path -Path $OutDir -ChildPath $fileName

if( (Test-Path -LiteralPath $OutFile -PathType Leaf) -and (-not $Force) ) {
	Write-Host "File already exists: $OutFile (use -Force to overwrite)" -ForegroundColor Yellow
	return
}

Write-Host "Downloading" -NoNewline; Write-Host " $Url" -ForegroundColor Cyan
Write-Host " -> $OutFile" -ForegroundColor Green

try {
	if(Get-Command -Name Start-BitsTransfer -ErrorAction SilentlyContinue) {
		Start-BitsTransfer -Source $Url -Destination $OutFile -ErrorAction Stop
	} else {
		Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
	}
	Write-Host "Done." -ForegroundColor Green
} catch {
	Write-Host "Failed: $_" -ForegroundColor Red
	exit 1
}
