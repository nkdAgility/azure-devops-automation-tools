# The functions that used to live in this file have moved to the
# NKDAgility.AzureDevOps.AutomationTools module under system\.
# This shim keeps existing runbooks that dot-source this file working.
Import-Module (Join-Path $PSScriptRoot '..\..\system\NKDAgility.AzureDevOps.AutomationTools') -Force
