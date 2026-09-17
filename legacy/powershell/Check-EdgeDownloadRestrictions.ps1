# Diagnose "Couldn't download - blocked" on Windows Server 2022
# Run in PowerShell 7+ as Administrator

$target = "https://software-download.microsoft.com/"

# 1) Microsoft Edge policies
$edgeKeys = @(
  "HKLM:\SOFTWARE\Policies\Microsoft\Edge",
  "HKCU:\SOFTWARE\Policies\Microsoft\Edge"
)
$edgeReport = foreach ($k in $edgeKeys) {
  if (Test-Path $k) {
    $p = Get-ItemProperty -Path $k
    [PSCustomObject]@{
      HivePath                                        = $k
      DownloadRestrictions                            = $p.DownloadRestrictions
      SmartScreenEnabled                               = $p.SmartScreenEnabled
      SmartScreenPuaEnabled                            = $p.SmartScreenPuaEnabled
      SmartScreenForTrustedDownloadsEnabled            = $p.SmartScreenForTrustedDownloadsEnabled
      ExemptFileTypeDownloadWarnings                   = $p.ExemptFileTypeDownloadWarnings
    }
  }
}

# 2) Microsoft Defender settings (Network Protection, PUA)
$mp = Get-MpPreference
$defenderReport = [PSCustomObject]@{
  PUAProtection           = $mp.PUAProtection            # 0 Off, 1 On, 2 Audit
  EnableNetworkProtection = $mp.EnableNetworkProtection  # 0 Off, 1 Block, 2 Audit
}

# 3) Attachment Manager (zone marking)
$attachCU = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments"
$attachLM = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments"
function Get-Attach {
  param($Path)
  if (Test-Path $Path) {
    $v = Get-ItemProperty -Path $Path
    [PSCustomObject]@{
      Path                   = $Path
      SaveZoneInformation    = $v.SaveZoneInformation    # 1 preserve, 2 do not preserve
      HideZoneInfoOnProperties = $v.HideZoneInfoOnProperties
    }
  }
}
$attachmentReport = @()
$attachmentReport += Get-Attach $attachCU
$attachmentReport += Get-Attach $attachLM

# 4) Proxies, WinHTTP vs browser
$winhttpProxy = (netsh winhttp show proxy) 2>$null
$ieKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$browserProxy = if (Test-Path $ieKey) { Get-ItemProperty -Path $ieKey |
  Select-Object @{n='ProxyEnable';e={$_.ProxyEnable}},
                @{n='ProxyServer';e={$_.ProxyServer}},
                @{n='AutoConfigURL';e={$_.AutoConfigURL}} }

# 5) Probe CDN with different User-Agents
function Test-Url {
  param($Url, $UA)
  try {
    $resp = Invoke-WebRequest -Uri $Url -Method Head -Headers @{ "User-Agent" = $UA } -TimeoutSec 20
    [PSCustomObject]@{ UserAgent=$UA; Status=$resp.StatusCode; Result="OK" }
  } catch {
    $code = try { $_.Exception.Response.StatusCode.Value__ } catch { $null }
    [PSCustomObject]@{ UserAgent=$UA; Status=$code; Result=$_.Exception.Message }
  }
}
$uas = @(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0",
  "PowerShell/7 Invoke-WebRequest"
)
$probes = foreach ($ua in $uas) { Test-Url -Url $target -UA $ua }

# 6) Output
"=== Edge Policy Report ==="; $edgeReport | Format-Table -AutoSize
"`n=== Defender Report ===";  $defenderReport | Format-List
"`n=== Attachment Manager ==="; $attachmentReport | Format-List
"`n=== Proxy Configuration ==="
"WinHTTP:`n$winhttpProxy"
"Browser proxy:"; $browserProxy | Format-List
"`n=== Network Probes ==="; $probes | Format-Table -AutoSize

"`n=== Quick Hints ==="
if ($edgeReport.DownloadRestrictions -contains 3) { "DownloadRestrictions=3 blocks all downloads in Edge." }
elseif ($edgeReport.DownloadRestrictions -contains 2) { "DownloadRestrictions=2 blocks potentially dangerous or unwanted downloads, ISO may be included by policy." }
elseif ($edgeReport.DownloadRestrictions -contains 1) { "DownloadRestrictions=1 blocks known dangerous types only." }
if ($edgeReport.SmartScreenEnabled -contains 1) { "SmartScreen enforced. Check Defender portal or local Reputation-based protection history." }
if ($defenderReport.EnableNetworkProtection -eq 1) { "Network Protection is in Block mode. Web content filtering or indicators can block browser traffic while PowerShell succeeds." }
if ($browserProxy.ProxyEnable -eq 1 -and -not $winhttpProxy.ToString().Contains("Direct access")) { "Different proxies for browser vs WinHTTP. Browser likely intercepted or category-filtered." }
if ($probes | Where-Object { $_.UserAgent -like "*Edg*" -and $_.Result -ne "OK" }) { "Edge UA fails while PowerShell UA passes. Likely proxy or category rule targeting browsers." }
