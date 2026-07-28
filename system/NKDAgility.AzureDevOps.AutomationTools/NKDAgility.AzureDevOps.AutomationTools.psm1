$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
$public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)

foreach ($file in ($private + $public)) {
    . $file.FullName
}

Export-ModuleMember -Function $public.BaseName
