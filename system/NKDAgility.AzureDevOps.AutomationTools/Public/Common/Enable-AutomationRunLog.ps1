function Enable-AutomationRunLog {
    <#
    .SYNOPSIS
    Wires run logging into existing engagement runbooks, which templates never update
    because they are seeds.

    .DESCRIPTION
    For each runbook it either:

    - converts the engagement-local pattern (`. "$PSScriptRoot\Start-RunLog.ps1" -Name X`,
      Stop-RunLog, Copy-RunLogArtifact) to the module functions, or
    - inserts `Start-AutomationRunLog -Name <file name>` and `try {` right after the line
      that dot-sources init.ps1, and appends `}` + `finally { Stop-AutomationRunLog }`.

    Skips a runbook that already calls Start-AutomationRunLog, has no init.ps1 line, or is
    run selection-by-selection (says so in its text) — wire those by hand, as the
    data-import templates show. Writes nothing under -WhatIf, and checks that each result
    still parses before writing it. Review the diff before committing.

    Tool log copies (Copy-AutomationRunLogArtifact for devopsmigration.exe) are not added;
    copy that block from the migration-tools Sync.ps1 template.

    .EXAMPLE
    Get-ChildItem .\migrations\03-Example\*.ps1 | Enable-AutomationRunLog -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')][string[]]$Path
    )

    process {
        foreach ($file in $Path) {
            $full = (Resolve-Path -LiteralPath $file).Path
            $name = [IO.Path]::GetFileNameWithoutExtension($full)
            if ($name -eq 'Start-RunLog') { continue }
            $raw = Get-Content -LiteralPath $full -Raw
            $nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
            $text = $raw -replace "`r`n", "`n"
            # The line matches below end in a newline; give a file whose last line is
            # init.ps1 one, so it is wired rather than skipped.
            if (-not $text.EndsWith("`n")) { $text += "`n" }

            if ($text -match 'Start-AutomationRunLog') {
                Write-Host "SKIP  $name - already wired" -ForegroundColor DarkGray
                continue
            }

            $localPattern = '(?m)^\.\s+"\$PSScriptRoot\\Start-RunLog\.ps1"\s+-Name\s+(''[^'']+''|"[^"]+"|\S+)\s*$'
            if ($text -match $localPattern) {
                $new = [regex]::Replace($text, $localPattern, 'Start-AutomationRunLog -Name $1')
                $new = $new -replace '\bStop-RunLog\b', 'Stop-AutomationRunLog' -replace '\bCopy-RunLogArtifact\b', 'Copy-AutomationRunLogArtifact'
                $action = 'convert Start-RunLog.ps1 to the module functions'
                # The local script was usually dot-sourced before init.ps1 loaded the
                # module; the module function must run after it, so move the line down.
                $start = [regex]::Match($new, '(?m)^Start-AutomationRunLog .*\n')
                $init = [regex]::Match($new, '(?m)^[ \t]*\.\s+"\$(here|PSScriptRoot)\\\.\.\\\.\.\\init\.ps1"[^\n]*\n')
                if ($init.Success -and $start.Index -lt $init.Index) {
                    $line = $start.Value
                    $new = $new.Insert($init.Index + $init.Length, $line).Remove($start.Index, $line.Length)
                    $action += ', after init.ps1'
                }
            }
            elseif ($text -match '(?i)selection-by-selection') {
                Write-Warning "SKIP  $name - run selection-by-selection; wire it by hand (see the data-import templates)."
                continue
            }
            else {
                $init = [regex]::Match($text, '(?m)^\.\s+"\$(here|PSScriptRoot)\\\.\.\\\.\.\\init\.ps1"[ \t]*\n')
                if (-not $init.Success) {
                    Write-Warning "SKIP  $name - no '. `"`$PSScriptRoot\..\..\init.ps1`"' line."
                    continue
                }
                $insert = "# Record this run's whole console to output\runs\ (committed engagement history).`n" +
                    "# Called from another runbook, it writes into the caller's log instead.`n" +
                    "Start-AutomationRunLog -Name '$name'`ntry {`n"
                $new = $text.Insert($init.Index + $init.Length, $insert).TrimEnd("`n") + "`n}`nfinally { Stop-AutomationRunLog }`n"
                $action = 'wrap in Start-AutomationRunLog / finally Stop-AutomationRunLog'
            }

            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseInput($new, [ref]$null, [ref]$errors)
            if ($errors) {
                Write-Warning "SKIP  $name - the change would not parse: $($errors[0].Message)"
                continue
            }
            if ($PSCmdlet.ShouldProcess($full, $action)) {
                Set-Content -LiteralPath $full -Value ($new -replace "`n", $nl) -NoNewline
                Write-Host "WIRED $name - $action" -ForegroundColor Green
            }
        }
    }
}
