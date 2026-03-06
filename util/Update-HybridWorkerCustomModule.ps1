<#
.SYNOPSIS
    Updates a custom PowerShell module on an Azure Automation Hybrid Worker VM and verifies the update.
.DESCRIPTION
    This script:
    - Authenticates to Azure and sets the correct context
    - Creates a zip from specified file paths (or uses an existing zip) and uploads to a storage account
    - Connects to the target Hybrid Worker VM
    - Places and extracts the module in the Hybrid Worker modules path
    - Reloads the module and verifies the update by invoking a test function

.PARAMETER FilePaths
    Array of .ps1 file paths to deploy. Paths must be under ModuleRootPath. Only these files are uploaded
    (preserving relative structure). Use this to update specific functions without deploying the whole module.

.PARAMETER ModuleRootPath
    Root path of the module (e.g. C:\Source\dxc-deployment-automation\InternalModules\EpiDeploy).
    Required when using FilePaths. Used to compute relative paths for the zip structure.

.PARAMETER ZipFilePath
    Alternative to FilePaths: path to an existing zip of the full module. If specified, FilePaths is ignored.

.NOTES
    Assumptions:
    - Az PowerShell modules are installed
    - VM and Storage permissions are available
    - If using FilePaths, the module must already exist on the Hybrid Worker; this overlays only the specified files
#>

param(
    [string] $automationAccountName = "IntegrationAutomation2",
    [string] $rgName = "IntegrationAutomation2",
    [string] $storageAccountName = "chngchuong1h3gz9",
    [string] $storageContainerName = "tmp",
    [string[]] $filePaths = @(
        "C:\Source\dxc-deployment-automation\InternalModules\EpiDeploy\EpiUtil\Public\Test-EpiResourceTagsNeedUpdate.ps1"
    ),
    [string] $moduleRootPath = "C:\Source\dxc-deployment-automation\InternalModules\EpiDeploy",
    [string] $zipFilePath = "", # If set, uses full zip instead of FilePaths
    [string] $hybridGroupName = "IntegrationAutomation2-HW-WestEurope",
    [string] $moduleName = "EpiDeploy",
    [string] $testFunctionName = "Test-EpiResourceTagsNeedUpdate"
)

# 1. Authenticate to Azure and set the context
Write-Host "Authenticating to Azure..."
Connect-AzAccount -ErrorAction Stop

Write-Host "Setting Azure context to resource group $rgName ..."
Set-AzContext -ResourceGroupName $rgName -ErrorAction Stop

# 2. Prepare zip and upload to storage
$storageAccount = Get-AzStorageAccount -ResourceGroupName $rgName -Name $storageAccountName
$ctx = $storageAccount.Context

if ($zipFilePath -and (Test-Path $zipFilePath)) {
    Write-Host "Using existing zip: $zipFilePath"
    $zipFilePathResolved = (Resolve-Path $zipFilePath).Path
    $zipFileName = Split-Path $zipFilePathResolved -Leaf
    Set-AzStorageBlobContent -File $zipFilePathResolved -Container $storageContainerName -Blob $zipFileName -Context $ctx -Force
}
else {
    Write-Host "Creating zip from $($filePaths.Count) file(s)..."
    $moduleRootResolved = (Resolve-Path $moduleRootPath).Path.TrimEnd('\', '/')
    $zipFileName = "$moduleName-patch-$(Get-Date -Format 'yyyyMMdd-HHmmss').zip"
    $tempZip = Join-Path $env:TEMP $zipFileName

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::Open($tempZip, 'Create').Dispose()
        $zip = [System.IO.Compression.ZipFile]::Open($tempZip, 'Update')
        foreach ($fp in $filePaths) {
            $fullPath = (Resolve-Path $fp).Path
            if ($fullPath -notlike "$moduleRootResolved*") {
                throw "File '$fullPath' is not under module root '$moduleRootResolved'."
            }
            $relativePath = $fullPath.Substring($moduleRootResolved.Length).TrimStart('\', '/')
            $zip.CreateEntryFromFile($fullPath, $relativePath, 'Optimal') | Out-Null
            Write-Host "  Added: $relativePath"
        }
        $zip.Dispose()
        Set-AzStorageBlobContent -File $tempZip -Container $storageContainerName -Blob $zipFileName -Context $ctx -Force
    }
    finally {
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force }
    }
}

# 3. Get Hybrid Worker group and worker VM
Write-Host "Retrieving Hybrid Worker group info..."
$hybridWorkerGroup = Get-AzAutomationHybridRunbookWorkerGroup -ResourceGroupName $rgName -AutomationAccountName $automationAccountName -Name $hybridGroupName
if (-not $hybridWorkerGroup) { throw "Hybrid Worker group not found!" }

$hybridWorker = $hybridWorkerGroup.RunbookWorkers | Select-Object -First 1
if (-not $hybridWorker) { throw "No hybrid worker found in group!" }

$vmResourceId = $hybridWorker.Name
$vm = Get-AzVM -ResourceId $vmResourceId
$vmName = $vm.Name

Write-Host "Target Hybrid Worker VM: $vmName"

# 4. Connect to VM (using Run Command for simplicity)
$scriptBlock = @'
param (
    [string] $blobUrl,
    [string] $moduleName
)
$modulePath = "C:\Program Files\WindowsPowerShell\Modules\$moduleName"
if (!(Test-Path $modulePath)) {
    New-Item -ItemType Directory -Path $modulePath -Force | Out-Null
}
$zipDest = "$env:TEMP\$moduleName.zip"
Invoke-WebRequest -Uri $blobUrl -OutFile $zipDest
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zipDest, $modulePath, $true)
Remove-Item $zipDest -Force
Write-Host "Module extracted to $modulePath."
# Reload module so subsequent runbooks pick up changes (Hybrid Worker caches modules)
Remove-Module $moduleName -Force -ErrorAction SilentlyContinue
Import-Module $moduleName -Force
Write-Host "Module reloaded."
'@

# Get the SAS URL for downloading the zip from blob storage
$expiry = (Get-Date).AddHours(2)
$sas = New-AzStorageBlobSASToken -Container $storageContainerName -Blob $zipFileName -Permission r -ExpiryTime $expiry -Context $ctx
$blobUrl = "$($storageAccount.PrimaryEndpoints.Blob)$storageContainerName/$zipFileName$sas"

Write-Host "Uploading and extracting module in VM..."
Invoke-AzVMRunCommand -ResourceGroupName $rgName -Name $vmName -CommandId 'RunPowerShellScript' -ScriptString $scriptBlock -Parameters @{ blobUrl=$blobUrl; moduleName=$moduleName }

# 5. Verify module is loaded and updated
Write-Host "Validating module and function update using $testFunctionName ..."
$verifyScript = @"
Remove-Module $moduleName -Force -ErrorAction SilentlyContinue
Import-Module $moduleName -Force
`$VerbosePreference = 'Continue'
try {
    `$result = & $testFunctionName -CurrentTag @{foo='bar'} -ExpectedTag @{foo='bar'}
    Write-Host "Function output: `$result"
} catch {
    Write-Error "Failed to run function: `$(`$_.Exception.Message)"
}
"@

$verifyResult = Invoke-AzVMRunCommand -ResourceGroupName $rgName -Name $vmName -CommandId 'RunPowerShellScript' -ScriptString $verifyScript

Write-Host "===== Function Output ====="
$verifyResult.Value | ForEach-Object { $_.Message }
Write-Host "=========================="

Write-Host "Module update and test complete."

