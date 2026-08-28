function Resolve-WitAdminPath {
    <#
    .SYNOPSIS
    Finds witadmin.exe, searching every product that ships it.

    .DESCRIPTION
    witadmin.exe is not a standalone download - it arrives with something else, and which
    something depends on where you are standing:

      * On the Azure DevOps Server / TFS machine itself it ships with the product, in
        '<ProgramFiles>\Azure DevOps Server <year>\Tools'. No Visual Studio required, and
        this is the usual place a migration engineer ends up running from.
      * On a workstation it comes with Visual Studio's Team Explorer. Visual Studio 2022
        is 64-bit and installs under ProgramFiles, earlier versions under ProgramFiles(x86),
        so both roots have to be searched.
      * SQL Server Management Studio also carries a Team Explorer, which is often the only
        copy on a DBA or build box.

    Searched cheapest-first: an explicit path, then PATH, then the product folders above.
    #>
    [CmdletBinding()]
    param([string]$WitAdminPath)

    if ($WitAdminPath) {
        if (Test-Path -LiteralPath $WitAdminPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $WitAdminPath).Path
        }
        throw "Unable to find witadmin at '$WitAdminPath'."
    }

    $command = Get-Command 'witadmin.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $programFiles = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique
    $searched = [System.Collections.Generic.List[string]]::new()

    # Get-ChildItem -Path <wildcard> -Recurse does NOT recurse into the folders the
    # wildcard matched - it silently returns nothing, which is how the SSMS copy of
    # witadmin was being missed on a machine that had one. Resolve the wildcard to real
    # directories first, then recurse each one by literal path.
    $findUnder = {
        param([string]$Glob, [switch]$Recurse)
        $searched.Add($Glob)
        foreach ($dir in @(Resolve-Path -Path $Glob -ErrorAction SilentlyContinue)) {
            $found = Get-ChildItem -LiteralPath $dir.Path -Filter 'witadmin.exe' -File -Recurse:$Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($found) { return $found.FullName }
        }
        return $null
    }

    # 1. The server product itself. A flat Tools folder, so no recursion - and this is the
    #    match we want first when running ON the server, where a stray Team Explorer copy
    #    could otherwise be older than the collection it is pointed at. Newest version
    #    first when several are installed side by side.
    foreach ($root in $programFiles) {
        foreach ($product in 'Azure DevOps Server *', 'Microsoft Team Foundation Server *') {
            $glob = Join-Path $root (Join-Path $product 'Tools')
            $searched.Add($glob)
            $dirs = @(Resolve-Path -Path $glob -ErrorAction SilentlyContinue | Sort-Object Path -Descending)
            foreach ($dir in $dirs) {
                $found = Get-ChildItem -LiteralPath $dir.Path -Filter 'witadmin.exe' -File -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($found) { return $found.FullName }
            }
        }
    }

    # 2. Visual Studio's Team Explorer, both bitnesses. VS 2022 is 64-bit and lands under
    #    ProgramFiles, so searching only the (x86) root misses it entirely.
    foreach ($root in $programFiles) {
        $hit = & $findUnder -Glob (Join-Path $root 'Microsoft Visual Studio') -Recurse
        if ($hit) { return $hit }
    }

    # 3. The Team Explorer that ships inside SQL Server Management Studio - often the only
    #    copy on a box that has no Visual Studio.
    foreach ($root in $programFiles) {
        $hit = & $findUnder -Glob (Join-Path $root 'Microsoft SQL Server Management Studio *') -Recurse
        if ($hit) { return $hit }
    }

    throw @"
Unable to find witadmin.exe. Searched PATH and:
$(($searched | ForEach-Object { "  $_" }) -join "`n")

witadmin is not a separate download. Either run this on the Azure DevOps Server itself
(it is in '<ProgramFiles>\Azure DevOps Server <year>\Tools'), install Visual Studio with
the Team Explorer / 'Azure DevOps Office Integration' component, or pass -WitAdminPath
with the full path to a copy. Its version should be no older than the collection it is
pointed at.
"@
}
