<#
.SYNOPSIS
    Invokes Invoke-AutomationAccountDeployment directly, bypassing credential-based authentication.

.DESCRIPTION
    Imports EpiAutomationDev and calls Invoke-AutomationAccountDeployment directly. Uses the current
    Azure context (Connect-AzAccount must be run beforehand). No SubscriptionId, AutomationUserName,
    or AutomationPassword are required.

.PARAMETER DxcDeploymentAutomationPath
    Path to the dxc-deployment-automation repo root.

.PARAMETER AutomationAccountName
    Name of the Azure Automation account.

.PARAMETER ResourceGroupName
    Resource group containing the Automation account.

.PARAMETER AutomationStorageAccountName
    Storage account used by the Automation account.

.PARAMETER AutomationAccountType
    Type: Production, Test, WebOpsTools, or EpiserverTools.

.PARAMETER ForceInternalModuleUpdate
    Force update of internal modules even if version is unchanged.

.PARAMETER SkipWindowsUpdate
    Skip Windows Update on Hybrid Workers.

.PARAMETER SkipDatadogUpdate
    Skip Datadog agent update on Hybrid Workers.

.NOTES
    Ensure you are logged in to Azure (Connect-AzAccount) and in the correct subscription before running.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $DxcDeploymentAutomationPath = "C:\Source\dxc-deployment-automation",

    [Parameter(Mandatory = $true)]
    [string] $AutomationAccountName,

    [Parameter(Mandatory = $true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string] $AutomationStorageAccountName,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Production', 'Test', 'WebOpsTools', 'EpiserverTools')]
    [string] $AutomationAccountType,

    [Parameter(Mandatory = $false)]
    [switch] $ForceInternalModuleUpdate,

    [Parameter(Mandatory = $false)]
    [switch] $SkipWindowsUpdate,

    [Parameter(Mandatory = $false)]
    [switch] $SkipDatadogUpdate,

    [Parameter(Mandatory = $false)]
    [string] $BuildNumber,

    [Parameter(Mandatory = $false)]
    [switch] $SkipHybridWorkerSync
)

$ErrorActionPreference = 'Stop'

$buildScriptsPath = Join-Path $DxcDeploymentAutomationPath "BuildScripts"
$modulePath = Join-Path $buildScriptsPath "EpiAutomationDev\EpiAutomationDev.psd1"
if (-not (Test-Path $modulePath)) {
    throw "EpiAutomationDev module not found at: $modulePath"
}

Push-Location $DxcDeploymentAutomationPath
try {
    Import-Module $modulePath -Verbose:$false -ErrorAction Stop -Force
    Import-RepoModule

    $deploymentParams = @{
        AutomationAccountName        = $AutomationAccountName
        ResourceGroupName            = $ResourceGroupName
        AutomationStorageAccountName = $AutomationStorageAccountName
        AutomationAccountType        = $AutomationAccountType
        PostFormattedLog             = $true
        SkipWindowsUpdate            = $SkipWindowsUpdate.IsPresent
        SkipDatadogUpdate            = $SkipDatadogUpdate.IsPresent
    }
    if ($ForceInternalModuleUpdate.IsPresent) {
        $deploymentParams.ForceInternalModuleUpdate = $true
    }
    if ($BuildNumber) {
        $deploymentParams.BuildNumber = $BuildNumber
    }
    if ($SkipHybridWorkerSync.IsPresent) {
        $deploymentParams.SkipHybridWorkerSync = $true
    }

    Invoke-AutomationAccountDeployment @deploymentParams
}
finally {
    Pop-Location
}
