
# Requires: PowerShell 7+
# Downloads to: $env:USERPROFILE\Downloads (override with -OutDir)
param(
  [string]$OutDir = [IO.Path]::Combine($env:USERPROFILE, "Downloads")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure output folder
if (-not (Test-Path -LiteralPath $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir | Out-Null
}

# Targets
$targets = @(
  @{ Name = "TFS2015U4Exe"; FwLink = "https://go.microsoft.com/fwlink/?LinkId=844068" },
  @{ Name = "TFS2015U4"; FwLink = "https://go.microsoft.com/fwlink/?LinkId=844069" },
  @{ Name = "AzureDevOpsServer2022exe"; FwLink = "https://go.microsoft.com/fwlink/?LinkId=2269844" }
  @{ Name = "AzureDevOpsServer2022"; FwLink = "https://go.microsoft.com/fwlink/?LinkId=2269752" }
)

function Resolve-FwLink {
  param([Parameter(Mandatory)][string]$Url)

  # Follow redirects without downloading the body
  $handler = [System.Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect = $true
  $client  = [System.Net.Http.HttpClient]::new($handler)
  $timeout = [TimeSpan]::FromSeconds(60)
  $client.Timeout = $timeout

  $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
  $resp = $client.Send($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)

  $finalUri = $resp.RequestMessage.RequestUri.AbsoluteUri

  # Try to get a filename from Content-Disposition, else from URL
  $dispo = $resp.Content.Headers.ContentDisposition
  if ($dispo -and ($dispo.FileNameStar -or $dispo.FileName)) {
    $name = $dispo.FileNameStar
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $dispo.FileName }
    $name = [System.Net.WebUtility]::UrlDecode($name.Trim('"'))
  } else {
    $name = [IO.Path]::GetFileName(([Uri]$finalUri).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'download.iso' }
  }

  # Dispose
  $resp.Dispose(); $client.Dispose(); $handler.Dispose()

  [PSCustomObject]@{ FinalUrl = $finalUri; FileName = $name }
}

function Download-File {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Destination
  )
  # Try BITS first, then fall back to Invoke-WebRequest
  try {
    Start-BitsTransfer -Source $Url -Destination $Destination -Description ("Downloading {0}" -f [IO.Path]::GetFileName($Destination)) -ErrorAction Stop
    return 'BITS'
  } catch {
    Invoke-WebRequest -Uri $Url -OutFile $Destination -ErrorAction Stop
    return 'Invoke-WebRequest'
  }
}

$results = foreach ($t in $targets) {
  Write-Host ("Resolving {0}..." -f $t.Name) -ForegroundColor Cyan
  $res = Resolve-FwLink -Url $t.FwLink

  $dest = Join-Path $OutDir $res.FileName
  Write-Host ("Downloading {0} -> {1}" -f $t.Name, $dest) -ForegroundColor Green
  $method = Download-File -Url $res.FinalUrl -Destination $dest

  $fi  = Get-Item -LiteralPath $dest
  $sha = Get-FileHash -LiteralPath $dest -Algorithm SHA256

  [PSCustomObject]@{
    Name      = $t.Name
    File      = $fi.FullName
    SizeGB    = [math]::Round($fi.Length / 1GB, 3)
    SHA256    = $sha.Hash
    Method    = $method
    SourceUrl = $res.FinalUrl
  }
}

"`nDownload summary:"
$results | Format-Table Name, SizeGB, Method, File -AutoSize

"`nSHA256 checksums:"
$results | Select-Object Name, SHA256 | Format-Table -AutoSize
