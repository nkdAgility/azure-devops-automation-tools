if ((Get-Module -Name ImportExcel -ListAvailable).count -eq 0) {
    Write-Warning -Message ('Module ImportExcel Missing.')
    Install-Module -Name ImportExcel -AllowClobber -Scope CurrentUser -force
}
else {
    Write-Information -Message ('Module ImportExcel Detected.')
}
Import-Module ImportExcel