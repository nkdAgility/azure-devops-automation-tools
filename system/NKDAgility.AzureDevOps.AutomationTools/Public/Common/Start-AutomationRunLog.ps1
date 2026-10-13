function Start-AutomationRunLog {
    <#
    .SYNOPSIS
    Records a runbook's whole console output to <engagement>\output\runs\, as committed
    engagement history.

    .DESCRIPTION
    Call right after the runbook dot-sources init.ps1, and put the body in a try/finally
    that calls Stop-AutomationRunLog, so a failed run is kept too:

        . "$PSScriptRoot\..\..\init.ps1"
        Start-AutomationRunLog -Name 'Sync'
        try { ... } finally { Stop-AutomationRunLog }

    The log is <engagement>\output\runs\<Name>-<yyyyMMdd-HHmmss>.log, started with
    Start-Transcript -IncludeInvocationHeader. The engagement folder is the calling
    script's folder unless -EngagementPath is given.

    A runbook called by another runbook (Sync.ps1 calling Run-Migrate-Repos.ps1) writes
    into its caller's log instead of starting a second one. The handoff lives in
    environment variables (NKDA_RUNLOG, NKDA_RUNLOG_DEPTH, NKDA_RUNLOG_PID) rather than
    module state, because every runbook re-imports the module through init.ps1, and so
    it also reaches child pwsh processes. Only the outermost Stop-AutomationRunLog in the
    owning process stops the transcript.

    .EXAMPLE
    Start-AutomationRunLog -Name 'Run-Migrate-Repos'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w.-]+$')][string]$Name,
        [string]$EngagementPath
    )

    if ($env:NKDA_RUNLOG) {
        # A log from a process that no longer exists (a killed session left the variables
        # behind) is stale; start a fresh one rather than writing into nothing.
        $ownerPid = 0
        [void][int]::TryParse([string]$env:NKDA_RUNLOG_PID, [ref]$ownerPid)
        $alive = $ownerPid -and (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)
        if ($alive) {
            if ($ownerPid -eq $PID) {
                $env:NKDA_RUNLOG_DEPTH = [string]([int]$env:NKDA_RUNLOG_DEPTH + 1)
            }
            Write-Host "==> Console log (continuing caller's): $env:NKDA_RUNLOG" -ForegroundColor DarkGray
            return
        }
        Remove-Item Env:\NKDA_RUNLOG, Env:\NKDA_RUNLOG_DEPTH, Env:\NKDA_RUNLOG_PID -ErrorAction SilentlyContinue
    }

    if (-not $EngagementPath) { $EngagementPath = $MyInvocation.PSScriptRoot }
    if (-not $EngagementPath) {
        throw 'Start-AutomationRunLog could not tell which engagement is running; call it from a runbook script or pass -EngagementPath.'
    }

    $runLogDir = Join-Path $EngagementPath 'output\runs'
    New-Item -ItemType Directory -Path $runLogDir -Force -ErrorAction Stop | Out-Null
    # Never overwrite an earlier run: a second start within the same second (a quick
    # retry, a concurrent run) gets -2, -3, ... -NoClobber settles a race between two
    # processes that both found a name free. -ErrorAction Stop because a failed start
    # must not leave the variables below claiming a log that is not being written.
    $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    for ($attempt = 1; ; $attempt++) {
        $leaf = if ($attempt -eq 1) { "$Name-$stamp.log" } else { "$Name-$stamp-$attempt.log" }
        $path = Join-Path $runLogDir $leaf
        if (Test-Path -LiteralPath $path) { continue }
        try {
            Start-Transcript -LiteralPath $path -IncludeInvocationHeader -NoClobber -ErrorAction Stop | Out-Null
            break
        }
        catch {
            # Taken between the check and the start: try the next name. Anything else is real.
            if ($attempt -ge 50 -or -not (Test-Path -LiteralPath $path)) { throw }
        }
    }
    $env:NKDA_RUNLOG = $path
    $env:NKDA_RUNLOG_DEPTH = '1'
    $env:NKDA_RUNLOG_PID = [string]$PID
    Write-Host "==> Console log: $path" -ForegroundColor DarkGray
}
