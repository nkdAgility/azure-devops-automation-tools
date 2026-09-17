function Invoke-FixStep {
    <#
    .SYNOPSIS
    Runs a named runbook step once, with optional verification, recording completion in a
    checkpoint file so re-running the runbook skips steps that already succeeded.

    .DESCRIPTION
    Designed for fix.ps1-style runbooks that must be executed a bit at a time against a
    live collection. Each step is a scriptblock; when it completes (and the optional
    -Verify scriptblock passes) the step name and timestamp are written to the checkpoint
    JSON. Running the same step again reports SKIP unless -Force is passed, so the whole
    runbook can be re-run top-to-bottom safely after a partial pass.

    A -Verify scriptblock fails the step if it throws or returns $false; the checkpoint is
    only written after verification passes.

    .EXAMPLE
    Invoke-FixStep -Name 'myproject-feedback-types' -Action {
        Install-FeedbackWorkItemTypes -Project 'MyProject' -TypeDefinitionsPath $agileTypeDefinitions
    } -Verify {
        (Get-WitWorkItemType -Project 'MyProject') -contains 'Feedback Request'
    }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Action,
        [scriptblock]$Verify,
        [string]$CheckpointPath = '.\fix-steps.checkpoint.json',
        [switch]$Force
    )

    $checkpoints = @{}
    if (Test-Path -LiteralPath $CheckpointPath -PathType Leaf) {
        $json = Get-Content -LiteralPath $CheckpointPath -Raw | ConvertFrom-Json
        foreach ($property in $json.PSObject.Properties) { $checkpoints[$property.Name] = $property.Value }
    }

    if (-not $Force -and $checkpoints.ContainsKey($Name)) {
        Write-FixStep "SKIP '$Name' - completed $($checkpoints[$Name]) (use -Force to re-run)"
        return
    }

    Write-FixStep "STEP '$Name' starting"
    & $Action

    if ($Verify) {
        Write-FixStep "STEP '$Name' verifying"
        $result = & $Verify
        if ($result -is [bool] -and -not $result) {
            throw "Step '$Name' failed verification."
        }
        Write-FixStep "STEP '$Name' verified"
    }

    $checkpoints[$Name] = (Get-Date).ToString('o')
    $parent = Split-Path -Parent $CheckpointPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $CheckpointPath -Value ($checkpoints | ConvertTo-Json)
    Write-FixStep "STEP '$Name' complete - checkpoint written"
}
