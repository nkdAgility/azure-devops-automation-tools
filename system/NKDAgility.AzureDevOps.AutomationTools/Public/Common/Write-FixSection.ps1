function Write-FixSection {
    <#
    .SYNOPSIS
    Prints a prominent console banner marking which runbook section is running,
    or - with -Minor - which item a loop is currently focused on.

    .EXAMPLE
    Write-FixSection '7. Process configuration for all projects'
    Write-FixSection -Minor "Project 'Acadia' (2 of 9) - feedback types + process configuration"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Title,
        [switch]$Minor
    )

    Write-Host ''
    if ($Minor) {
        Write-Host "[fix] --- $Title ---" -ForegroundColor Yellow
    }
    else {
        Write-Host "[fix] $('=' * 74)" -ForegroundColor Yellow
        Write-Host "[fix] SECTION $Title" -ForegroundColor Yellow
        Write-Host "[fix] $('=' * 74)" -ForegroundColor Yellow
    }
}
