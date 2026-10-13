function Stop-AutomationRunLog {
    <#
    .SYNOPSIS
    Ends the run log started by Start-AutomationRunLog. Call it in a finally block.

    .DESCRIPTION
    Each call matches one Start-AutomationRunLog in the same process. Only the outermost
    one stops the transcript and clears the NKDA_RUNLOG variables; a nested runbook's call,
    or one in a child process that joined its caller's log, leaves the caller's log open.
    Safe to call when no log is running.
    #>
    [CmdletBinding()]
    param()

    if (-not $env:NKDA_RUNLOG -or [string]$env:NKDA_RUNLOG_PID -ne [string]$PID) { return }

    $depth = [int]$env:NKDA_RUNLOG_DEPTH - 1
    if ($depth -gt 0) {
        $env:NKDA_RUNLOG_DEPTH = [string]$depth
        return
    }

    $path = $env:NKDA_RUNLOG
    Remove-Item Env:\NKDA_RUNLOG, Env:\NKDA_RUNLOG_DEPTH, Env:\NKDA_RUNLOG_PID -ErrorAction SilentlyContinue
    Write-Host "==> Console log saved: $path" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { Write-Verbose "No transcript to stop: $_" }
}
