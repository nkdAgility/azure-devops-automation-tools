# The module's own root. Every function that needs a file shipped with the module
# resolves it from here - never by walking up from $PSScriptRoot or ModuleBase.
# The module is copied out of this repo into a client workspace's .system\ folder,
# so anything above this folder does not exist at runtime.
$script:ModuleRoot = $PSScriptRoot

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
$public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)

foreach ($file in ($private + $public)) {
    . $file.FullName
}

Export-ModuleMember -Function $public.BaseName
