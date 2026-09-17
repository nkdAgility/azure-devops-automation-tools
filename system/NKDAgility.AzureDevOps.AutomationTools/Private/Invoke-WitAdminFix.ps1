function Invoke-WitAdminFix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$WitAdminPath
    )

    $executable = Resolve-WitAdminPath -WitAdminPath $WitAdminPath
    Write-FixStep "witadmin $($Arguments -join ' ')"
    # Capture stdout/stderr rather than emitting it: callers use this for side
    # effects only, and witadmin chatter must not pollute the output stream of
    # object-emitting functions like Get-WitWorkItemTypeState.
    $output = & $executable @Arguments 2>&1
    foreach ($line in $output) {
        if ("$line".Trim()) { Write-FixStep "  $line" }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "witadmin failed with exit code $LASTEXITCODE. $(($output -join ' ').Trim())"
    }
    # witadmin sometimes exits 0 despite failing (observed: importwitd TF237070
    # schema rejection), so also treat TF/VS-coded errors in the output as failure.
    $errorLines = @($output | Where-Object { "$_" -match '\b(TF|VS)\d{5,7}\b' -and "$_" -notmatch '(?i)warning' })
    if ($errorLines) {
        throw "witadmin reported an error despite exit code 0: $(($errorLines -join ' ').Trim())"
    }
}
