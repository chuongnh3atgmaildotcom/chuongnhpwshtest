#region import module
Set-Location -Path "C:\Source\dxc-deployment-automation\InternalModules\EpiDeploy"
# Verify the current location
$currentLocation = Get-Location
Write-Host "Current directory: $($currentLocation.Path)"
Import-Module -Name EpiDeploy
#import the pds1
Import-Module -Name "C:\Source\dxc-deployment-automation\InternalModules\EpiDeploy\EpiDeploy.psd1" -Force -Verbose
#module bin path
$mod = Get-Module -Name EpiDeploy -ListAvailable
$moduleBase = Split-Path -Parent $mod.Path
$binPath = Join-Path $moduleBase "bin"
Write-Host "Module base: $moduleBase"
Write-Host "Bin path:   $binPath"
Write-Host "bin exists: $(Test-Path $binPath)"
Get-ChildItem $binPath -Filter "*.dll" | ForEach-Object { Write-Host "  $($_.FullName)  Length=$($_.Length)" }
# RequiredAssemblies from EpiDeploy.psd1 (same order as manifest)
$requiredDlls = @('.\bin\Microsoft.Web.XmlTransform.dll', '.\bin\libidn.dll')
Write-Host "`n--- Simulate module loader: LoadFrom each in order ---"
$firstFailingDll = $null
foreach ($rel in $requiredDlls) {
    $fullPath = Join-Path $moduleBase $rel
    if (-not (Test-Path -LiteralPath $fullPath)) {
        Write-Host "  SKIP (not found): $fullPath"
        continue
    }
    $fullPath = (Resolve-Path -LiteralPath $fullPath).Path
    Write-Host "  Loading: $fullPath"
    try {
        $null = [System.Reflection.Assembly]::LoadFrom($fullPath)
        Write-Host "    -> OK"
    }
    catch {
        Write-Host "    -> FAILED: $($_.Exception.Message)"
        if ($_.Exception.InnerException) { Write-Host "       Inner: $($_.Exception.InnerException.Message)" }
        if (-not $firstFailingDll) { $firstFailingDll = $rel }
    }
}
if ($firstFailingDll) { Write-Host ">>> First failing DLL (simulation): $firstFailingDll" }

# Actual Import-Module (PowerShell's loader; may differ from LoadFrom)
$ErrorActionPreference = 'Stop'
Write-Host "`n--- Import-Module EpiDeploy ---"
# Get hybrid-worker-level verbose: "Loading module from path...", "Loading 'Assembly' from path..."
$VerbosePreference = 'Continue'
try {
    Import-Module -Name EpiDeploy -Force -Verbose
    Write-Host "Import succeeded"
}
catch {
    Write-Host "Import-Module FAILED"
    Write-Host "Exception: $($_.Exception.GetType().FullName)"
    Write-Host "Message: $($_.Exception.Message)"
    Write-Host "StackTrace: $($_.Exception.StackTrace)"
    if ($_.Exception.InnerException) {
        Write-Host "Inner: $($_.Exception.InnerException.Message)"
        Write-Host "Inner StackTrace: $($_.Exception.InnerException.StackTrace)"
    }
    Write-Host "If simulation passed but this failed, PowerShell's loader differs from LoadFrom."
}
#endregion

#region check module
Get-Module Az* -ListAvailable | Select-Object Name, Version
Get-Command -Module Az.* | Select-String Connect-Az*
Get-Module Az.Accounts -ListAvailable | Select-Object Name, Version, ModuleBase, Path
$env:Path -split ';'
#endregion

#region az auth
Connect-AzAccount
#set subscription to CHNG Chuong Nguyen
Set-AzContext -Subscription "d34b6707-c9e0-4fd4-a412-adecf0b5a352"

# Check and display the currently authenticated Azure account context
$context = Get-AzContext
if ($null -eq $context) {
    Write-Output "No Azure context is currently set. Please authenticate using Connect-AzAccount."
} else {
    Write-Output ("Current Azure session: Account = '{0}', Subscription = '{1}', Tenant = '{2}'" -f $context.Account, $context.Subscription, $context.Tenant.Id)
}
#endregion

#region global preference
Add-Perry -Interactive -IncludeException
$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'
#endregion



#region import module in docker servercore:ltsc2022
# Use a path that stays valid when lowercased by Docker
$EpiDeployPath = "C:\Source\dxc-deployment-automation\InternalModules\EpiDeploy"
$DockerMountPath = "C:\temp\epideploy"
New-Item -ItemType Directory -Path $DockerMountPath -Force | Out-Null
Copy-Item -Path "$EpiDeployPath\*" -Destination $DockerMountPath -Recurse -Force

docker run --rm `
    -v "${DockerMountPath}:C:\EpiDeploy:ro" `
    mcr.microsoft.com/windows/servercore:ltsc2022 `
    powershell -NoProfile -Command @"
`$VerbosePreference = 'Continue'
Write-Host '--- PSVersion (container) ---'
`$PSVersionTable
Write-Host ''
Write-Host '--- Import-Module EpiDeploy ---'
Import-Module -Name 'C:\EpiDeploy\EpiDeploy.psd1' -Force -Verbose
Write-Host ''
Write-Host 'SUCCESS: EpiDeploy loaded (same engine as hybrid worker)'
"@
#add internal module path to $env:PSModulePath then import from different location
$RepoRoot = "C:\Source\dxc-deployment-automation"
$DockerRepoPath = "C:\temp\dxc-deployment-automation"
if (-not (Test-Path $DockerRepoPath)) { New-Item -ItemType Directory -Path $DockerRepoPath -Force | Out-Null }
Copy-Item -Path "$RepoRoot\InternalModules" -Destination "$DockerRepoPath\InternalModules" -Recurse -Force
docker run --rm `
  -v "${DockerRepoPath}:C:\repo:ro" `
  mcr.microsoft.com/windows/servercore:ltsc2022 `
  powershell -NoProfile -Command @"

# Emulate (2): InternalModules as module path, current dir = repo root
`$env:PSModulePath = 'C:\repo\InternalModules;' + `$env:PSModulePath
Set-Location -Path 'C:\repo'
Write-Host '--- PSVersion (container) ---'
`$PSVersionTable
Write-Host ''
Write-Host '--- (Get-Module -Name EpiDeploy -ListAvailable).Path ---'
(Get-Module -Name EpiDeploy -ListAvailable).Path
Write-Host ''
Write-Host '--- Import-Module -Name EpiDeploy (from repo root) ---'
Import-Module -Name EpiDeploy -Force
Write-Host ''
Write-Host 'SUCCESS: Identical to Win 11 scenario (2) but on 20348 engine'
"@
#endregion


#region ObjectId lookup (collapsible in editors that support regions)
$objectId = '5d86cafb-81da-4fc5-baa9-4ff0540a7290'
# Try service principal (most common for Key Vault access)
$sp = Get-AzADServicePrincipal -ObjectId $objectId -ErrorAction SilentlyContinue
if ($sp) {
    Write-Output "Found Service Principal:`n$($sp | Format-List | Out-String)"
}
else {
    # If not found, try user
    $user = Get-AzADUser -ObjectId $objectId -ErrorAction SilentlyContinue
    if ($user) {
        Write-Output "Found User:`n$($user | Format-List | Out-String)"
    }
    else {
        # If not found, try group
        $group = Get-AzADGroup -ObjectId $objectId -ErrorAction SilentlyContinue
        if ($group) {
            Write-Output "Found Group:`n$($group | Format-List | Out-String)"
        }
        else {
            Write-Output "No Service Principal, User, or Group with ObjectId '$objectId' was found."
        }
    }
}
#endregion


#region get deployments
$maxResourceGroupTimestamp = (Get-Date).ToUniversalTime().AddHours(-1)
Get-AzResourceGroupDeployment -ResourceGroupName "ngdkfailove0ex96" |
Where-Object { $_.Timestamp -lt $maxResourceGroupTimestamp } |
Select-Object -ExpandProperty ResourceGroupName -Unique
#endregion


#region WIP Update Hybrid Worker DSC
C:\Source\chuongnhpwshtest\util\Update-HybridWorkerDSC.ps1 `
    -AutomationAccountName "IntegrationAutomation2" `
    -ResourceGroupName "IntegrationAutomation2" `
    -AutomationStorageAccountName "integrationautomblob6572" `
    -AutomationAccountType "Test" `
    -ForceInternalModuleUpdate
#endregion


#region IIS Express Config Path Resolution

# 1. Get the user's true Documents directory (respects OneDrive/document redirection)
$realDocumentsPath = [Environment]::GetFolderPath('Personal')
Write-Host "Resolved Documents Path: $realDocumentsPath" -ForegroundColor Cyan

# 2. Build the expected IIS Express config file path
$iisExpressConfig = Join-Path $realDocumentsPath "IISExpress\config\applicationhost.config"
Write-Host "Checking IIS Express config path: $iisExpressConfig" -ForegroundColor Yellow

# 3. Validate existence and search for the 'PaaS' site entry
if (Test-Path $iisExpressConfig) {
    $paasSite = Select-String -Path $iisExpressConfig -Pattern 'name="PaaS"'
    if ($paasSite) {
        Write-Host "Site 'PaaS' entry FOUND in: $iisExpressConfig" -ForegroundColor Green
        $paasSite
    }
    else {
        Write-Host "Site 'PaaS' NOT found in config. IIS Express may be using a custom location." -ForegroundColor Red
    }
}
else {
    Write-Host "IIS Express config not found at expected Documents location!" -ForegroundColor Red
}

# 4. Show relevant environment variables and alternative config path
Write-Host "`n--- IIS Environment Overrides Check ---"
Write-Host ("IIS_USER_HOME: {0}" -f $env:IIS_USER_HOME)
Write-Host ("APP_HOST_CONFIG: {0}" -f $env:APP_HOST_CONFIG)

# 5. Hardcoded known-good config path and explicit IIS Express launch for 'PaaS' site
$knownGoodConfig = "C:\Users\ChuongNguyen\OneDrive - Episerver\Documents\IISExpress\config\applicationhost.config"
Write-Host ("Known-Good Config Path: {0}" -f $knownGoodConfig) -ForegroundColor Magenta

# You can launch the specific IIS Express site directly:
& "C:\Program Files\IIS Express\iisexpress.exe" /config:$knownGoodConfig /site:"PaaS"

#endregion


#region test Azure.PaaSServiceAccount credential
$clientId = "89555e60-fb10-4409-aaa9-71c223f0fe4d"
#objectID 57b2961e-9a7a-4b2e-9d7d-2a3e13a095db
$clientSecret = ""
$tenantId = "c6d260b3-0c63-4ced-b15b-ed462d08c5c4"
$secureSecret = $clientSecret | ConvertTo-SecureString -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($clientId, $secureSecret)
Connect-AzAccount -ServicePrincipal -TenantId $tenantId -Credential $credential -Subscription "c58e3edc-13cf-497b-bcd3-d0cf2feaf596"
$token = Get-AzAccessToken -Resource "https://management.azure.com/"
Write-Host "Token: $($token.Token)"

#appid from the error log
$vsappid = "04f0c124-f2bc-4f59-8241-bf6df9866bbd"
Get-AzADServicePrincipal -ApplicationId $vsappid -ErrorAction Stop -Verbose
#hope this match oid from the error log: f9a54707-897e-4cbd-a649-ded412570e4d

# --- Verify (match portal) ---
# 1. App ID and Object ID from credentials key (this service principal)
Write-Host "`n--- 1. Credentials key (AppId / ObjectId) ---" -ForegroundColor Cyan
Write-Host "AppId (ApplicationId): $clientId"
$sp = Get-AzADServicePrincipal -ApplicationId $clientId -ErrorAction SilentlyContinue
if ($sp) {
    Write-Host "ObjectId:             $($sp.Id)"
    Write-Host "DisplayName:          $($sp.DisplayName)"
}
Write-Host ("ObjectId: {0}" -f ($(if ($sp) { $sp.Id } else { "(not found)" })))



# 2. Vault name from Portal Web.config KeyVaultBaseUrl
Write-Host "`n--- 2. Vault name ---" -ForegroundColor Cyan
$webConfigPath = "C:\Source\PaaS\PaaS\EPiServer.PaaS.Portal\Web.config"
$config = [xml](Get-Content -Path $webConfigPath -Raw)
$appSettings = $config.configuration.appSettings.add | Where-Object { $_.key }
$getConfig = { param($key) ($appSettings | Where-Object { $_.key -eq $key }).value }
$keyVaultBaseUrl = & $getConfig "KeyVaultBaseUrl"
if ($keyVaultBaseUrl -match 'https://([^/.]+)\.vault\.') {
    if ($keyVaultBaseUrl -match 'https://([^/.]+)\.vault\.') {
        $vaultName = $Matches[1]
        Write-Host "VaultName: $vaultName"
        Write-Host "KeyVaultBaseUrl: $keyVaultBaseUrl"
    }
    else {
        $vaultName = $null
        Write-Host "Could not parse vault name from KeyVaultBaseUrl: $keyVaultBaseUrl"
    }
}

# 3. View access policies
Write-Host "`n--- 3. Access policies (portal: Key Vault -> Access policies) ---" -ForegroundColor Cyan
if ($vaultName) {
    $kv = Get-AzKeyVault -VaultName $vaultName -ErrorAction SilentlyContinue
    if ($kv) {
        $policies = $kv.AccessPolicies
        Write-Host "Vault: $($kv.VaultName) (ResourceGroup: $($kv.ResourceGroupName))"
        Write-Host "Access policy count: $($policies.Count)"
        foreach ($p in $policies) {
            Write-Host "  ObjectId: $($p.ObjectId)  |  TenantId: $($p.TenantId)"
            Write-Host "    Keys:   $($p.PermissionsToKeys -join ', ')"
            Write-Host "    Secrets: $($p.PermissionsToSecrets -join ', ')"
            Write-Host "    Certs:  $($p.PermissionsToCertificates -join ', ')"
        }
    }
    else {
        Write-Host "Key Vault '$vaultName' not found. Context: $(Get-AzContext | Select-Object -ExpandProperty Name)"
    }
}
#endregion

#region investigate web app
#count webapp efficiently without getting all apps
(Get-AzResource -ResourceType Microsoft.Web/sites | Where-Object { $_.ResourceId -notmatch '/slots/' }).Count
#ls app name + OS from my subscription using Get-AzResource 
Get-AzResource -ResourceType Microsoft.Web/sites | Where-Object { $_.ResourceId -notmatch '/slots/' } | Select-Object Name, @{Name='OS'; Expression={ if ($_.Kind -match 'linux') { 'Linux' } else { 'Windows' } } }

#slot name
$resourceGroupName = "chngcommerc99sabs001"
$webAppName = "chngcommerc99sabs001"
$slots = Get-AzWebAppSlot -ResourceGroupName $resourceGroupName -Name $webAppName
if ($slots) {
    Write-Host "Slots found:"
    foreach ($slot in $slots) {
        Write-Host "  - $($slot.Name)"
    }
} else {
    Write-Host "No slots found for site 'chngcommerc99sabs001' in resource group 'chngcommerc99sabs001'."
}
#endregion

#region paas-30620 kuduswitch
#run on linuxcommerce slot


Invoke-EpiKuduCommand -SiteName "PaaS" -Credential $credential -Command "dir"
#endregion

#region set vault policy
# Set Key Vault access policy for a principal with all secret permissions.
$vaultName = "chngchuong1h3gz9inte"
$resourceGroupName = "chngchuong1h3gz9inte"
$ctx = Get-AzContext
# Show all properties of the current context ($ctx)
Write-Host "Current AzContext properties:"
$ctx | Format-List *
#expand the account object
$ctx.Account | Format-List *
Write-Host "No service principal found for ApplicationId $($ctx.Account.Id)"

#so far I only find a way to get object ID from user email, independence from any id in context
$chuongnhObjectId = (Get-AzADUser -Mail "chuong.nguyen@optimizely.com").Id
#check my policy (normalize ObjectId to string so filter works across Guid/string types)
$kv = Get-AzKeyVault -VaultName $vaultName -ResourceGroupName $resourceGroupName
$kv.AccessPolicies | Where-Object { [string]$_.ObjectId -eq $chuongnhObjectId } | Format-List *
#set policy
$secretPermissions = @("Get", "List", "Set", "Delete", "Backup", "Restore", "Recover", "Purge")
Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ResourceGroupName $resourceGroupName -ObjectId 'f9a54707-897e-4cbd-a649-ded412570e4d' -PermissionsToSecrets $secretPermissions
#endregion

#region deploy
Import-Module C:\Source\epicloud\source\EpiCloud -Force
$global:epiCloudApiEndpointUri = "https://paasportal.epimore.com/api/v1.0/"
function Invoke-AlloyDeployment {
    param (
        [string]$PackageName = "cms.app.0.0.1.1.nupkg",
        [string]$PackagePath = "C:\Source\chuongnhpwshtest\cms.app.0.0.1.1.nupkg",
        [string]$TargetEnvironment = "Integration"
    )
    # Upload .NET Core Alloy to blob storage
    $sasUrl = Get-EpiDeploymentPackageLocation
    Add-EpiDeploymentPackage -SasUrl $sasUrl -Path $PackagePath
    #trigger an empty deployment
    $output = Start-EpiDeployment -DeploymentPackage $PackageName -TargetEnvironment $TargetEnvironment
    $output
}
$packageName = "cms.app.0.0.1.1.nupkg"
$packagePath = "C:\Source\chuongnhpwshtest\cms.app.0.0.1.1.nupkg"
$targetEnvironment = "Integration"
#deploy with slot swap (linxux)
$resourceGroupName = "chngchuong1h3gz9inte"
$webAppName = "chngchuong1h3gz9inte"
$projectId = "c1e1362c-e965-4ed0-a94c-b3e00046c814"
$clientKey = "2eRycsVExOOPWPVztbx1W3CPeDTSLqNIUeXF2uL0jmNj5eYT"
$clientSecret = ""
# Connect EpiCloud using credentials from portal
Connect-EpiCloud -ProjectId $projectId -ClientKey $clientKey -ClientSecret $clientSecret
$swapID = (Invoke-AlloyDeployment -PackageName $packageName -PackagePath $packagePath -TargetEnvironment $targetEnvironment).Id
$swapID

#deploy with slot swap (window)
$resourceGroupName = "mgrchngcommercxa74ninte"
$webAppName = "mgrchngcommercxa74ninte"
$projectId = ""
$clientKey = ""
$clientSecret = ""
# Connect EpiCloud using credentials from portal
Connect-EpiCloud -ProjectId $projectId -ClientKey $clientKey -ClientSecret $clientSecret
$swapID = (Invoke-AlloyDeployment -PackageName $packageName -PackagePath $packagePath -TargetEnvironment $targetEnvironment).Id
$swapID

#complete or reset
Complete-EpiDeployment -Id $swapID
Reset-EpiDeployment -Id 'ea762333-0e04-4d2c-8af2-b3f0001e1ac6'
#endregion