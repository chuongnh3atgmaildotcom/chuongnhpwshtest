#region load .env (same dir as script)
$envDir = if ($PSScriptRoot) { $PSScriptRoot } else { "C:\Source\chuongnhpwshtest\util" }
$envPath = Join-Path $envDir 'runner.env'
if (-not (Test-Path -LiteralPath $envPath)) {
    throw "Missing .env at: $envPath. Create from .env.example or add Az/CF/EpiCloud credentials and IDs."
}
$envLoadedKeys = [System.Collections.ArrayList]@()
Get-Content -LiteralPath $envPath -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -and $line -notmatch '^\s*#') {
        $firstEq = $line.IndexOf('=')
        if ($firstEq -gt 0) {
            $key = $line.Substring(0, $firstEq).Trim()
            $value = $line.Substring($firstEq + 1).Trim()
            if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            [void]$envLoadedKeys.Add($key)
            Set-Variable -Scope Script -Name $key -Value $value -ErrorAction SilentlyContinue
            if ($key -eq 'vaultName') { $script:VaultNameForPolicy = $value }
        }
    }
}
foreach ($k in $envLoadedKeys) {
    $v = (Get-Variable -Scope Script -Name $k -ErrorAction SilentlyContinue).Value
    Write-Host "$k = $v"
}
#endregion

#region import module
Set-Location -Path "C:\Source\dxc-deployment-automation\InternalModules\EpiDeploy"
# module path
$env:PSModulePath -split ';'
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
Get-Help Invoke-Pester -Full
Get-Module Az.Accounts -ListAvailable | Select-Object Name, Version, ModuleBase, Path
Write-Host "`n--- Path ---"
$env:Path -split ';' | ForEach-Object { Write-Host "  $_" }
Write-Host "`n--- PSModulePath ---"
$env:PSModulePath -split ';' | ForEach-Object { Write-Host "  $_" }
"C:\Users\ChuongNguyen\OneDrive - Episerver\\Documents\PowerShell\Modules\Az*" | ForEach-Object { if (Test-Path $_) { Remove-Item $_ -Recurse -Force } }
#endregion

#region az auth
Connect-AzAccount
#set subscription to CHNG Chuong Nguyen (from .env: AzContextSubscriptionId)
Set-AzContext -Subscription $AzContextSubscriptionId
#set subscription to DXCT paastest management subscription
# Set-AzContext -Subscription "c58e3edc-13cf-497b-bcd3-d0cf2feaf596"
# Check and display the currently authenticated Azure account context
$context = Get-AzContext
if ($null -eq $context) {
    Write-Output "No Azure context is currently set. Please authenticate using Connect-AzAccount."
} else {
    # Display the current Azure session info, including subscription name, for @PowerShell @Azure App Service context
    Write-Output ("Current Azure session: Account = '{0}', SubscriptionId = '{1}', SubscriptionName = '{2}', TenantId = '{3}'" -f $context.Account, $context.Subscription.Id, $context.Subscription.Name, $context.Tenant.Id)
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


#region ObjectId lookup (objectId from .env)
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


#region test Azure.PaaSServiceAccount credential (clientId, clientSecret, tenantId, AzServicePrincipalSubscriptionId from .env)
$secureSecret = $clientSecret | ConvertTo-SecureString -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($clientId, $secureSecret)
Connect-AzAccount -ServicePrincipal -TenantId $tenantId -Credential $credential -Subscription $AzServicePrincipalSubscriptionId
$token = Get-AzAccessToken -Resource "https://management.azure.com/"
# Do not log token; remove or redact if debugging

#appid from the error log (vsappid from .env)
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
$ctx = Get-AzContext
# Show all properties of the current context ($ctx)
Write-Host "Current AzContext properties:"
$ctx | Format-List *
#expand the account object
$ctx.Account | Format-List *

#so far I only find a way to get object ID from user email (AzAdUserMail from .env)
$chuongnhObjectId = (Get-AzADUser -Mail $AzAdUserMail).Id
#get vault (from .env; use VaultNameForPolicy so Web.config parse in previous region does not override)
$vaultName = $VaultNameForPolicy
$resourceGroupName = $vaultResourceGroupName
# List all Key Vault names in a given resource group using Get-AzResource (efficient, no ARM throttling for vaults)
$keyVaults = Get-AzResource -ResourceGroupName $resourceGroupName -ResourceType "Microsoft.KeyVault/vaults"
if ($keyVaults) {
    Write-Host "Key Vaults in resource group '$resourceGroupName':"
    $keyVaults | Select-Object -ExpandProperty Name | ForEach-Object { Write-Host "  - $_" }
} else {
    Write-Host "No Key Vaults found in resource group '$resourceGroupName'."
}
#get vault
$kv = Get-AzKeyVault -VaultName $vaultName -ResourceGroupName $resourceGroupName -Verbose
if (-not $kv) {
    Write-Warning "Key Vault '$vaultName' not found in resource group '$resourceGroupName'."
}
#check my policy
$kv.AccessPolicies | Where-Object { [string]$_.ObjectId -eq $chuongnhObjectId } | Format-List *
# Get all secrets in the vault whose names contain 'mongo' (case-insensitive)
$mongoSecrets = Get-AzKeyVaultSecret -VaultName $vaultName | Where-Object { $_.Name -match 'mongo' }
if ($mongoSecrets) {
    Write-Host "Found secrets containing 'mongo' in their names:"
    $mongoSecrets | Select-Object Name, Id
} else {
    Write-Host "No secrets containing 'mongo' found in Key Vault '$vaultName'."
}

#set policy
$secretPermissions = @("Get", "List", "Set", "Delete", "Backup", "Restore", "Recover", "Purge")
Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ResourceGroupName $resourceGroupName -ObjectId $chuongnhObjectId -PermissionsToSecrets $secretPermissions
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
#deploy with slot swap (linxux) — EpiCloudProjectId, EpiCloudClientKey, EpiCloudClientSecret from .env
$resourceGroupName = "chngchuong1h3gz9inte"
$webAppName = "chngchuong1h3gz9inte"
Connect-EpiCloud -ProjectId $EpiCloudProjectId -ClientKey $EpiCloudClientKey -ClientSecret $EpiCloudClientSecret
$swapID = (Invoke-AlloyDeployment -PackageName $packageName -PackagePath $packagePath -TargetEnvironment $targetEnvironment).Id
$swapID

#deploy with slot swap (window) — optional second project; add EpiCloudProjectId2, EpiCloudClientKey2, EpiCloudClientSecret2 to .env to run
$resourceGroupName = "mgrchngcommercxa74ninte"
$webAppName = "mgrchngcommercxa74ninte"
if ($EpiCloudProjectId2 -and $EpiCloudClientKey2 -and $EpiCloudClientSecret2) {
    Connect-EpiCloud -ProjectId $EpiCloudProjectId2 -ClientKey $EpiCloudClientKey2 -ClientSecret $EpiCloudClientSecret2
    $swapID = (Invoke-AlloyDeployment -PackageName $packageName -PackagePath $packagePath -TargetEnvironment $targetEnvironment).Id
    $swapID
} else {
    Write-Host "EpiCloudProjectId2 / EpiCloudClientKey2 / EpiCloudClientSecret2 not set in .env; skipping second deploy."
}

#complete or reset (EpiDeploymentResetId from .env)
Complete-EpiDeployment -Id $swapID
Reset-EpiDeployment -Id $EpiDeploymentResetId
#endregion

#region create service bus resource
$location = "North Europe"
$sbResourceGroupName = "chng-dev"
# Create the resource group if it does not exist, then show group info
$sbResourceGroup = Get-AzResourceGroup -Name $sbResourceGroupName -ErrorAction SilentlyContinue
if (-not $sbResourceGroup) {
    Write-Host "Creating resource group: $sbResourceGroupName"
    $sbResourceGroup = New-AzResourceGroup -Name $sbResourceGroupName -Location $location
} else {
    Write-Host "Resource group '$sbResourceGroupName' already exists."
}
Write-Host "Resource group info:"
$sbResourceGroup | Format-List
$sbNamespaceName = "chng-dev"

# Check if the Service Bus Namespace already exists
$sbNamespace = Get-AzServiceBusNamespace -ResourceGroupName $sbResourceGroupName -Name $sbNamespaceName -ErrorAction SilentlyContinue
if (-not $sbNamespace) {
    Write-Host "Creating Service Bus Namespace: $sbNamespaceName in Standard tier"
    $sbNamespace = New-AzServiceBusNamespace -ResourceGroupName $sbResourceGroupName `
        -Name $sbNamespaceName `
        -Location $location `
        -SkuName "Standard"
} else {
    Write-Host "Service Bus Namespace '$sbNamespaceName' already exists."
}
Write-Host "Service Bus Namespace info:"
$sbNamespace | Format-List *

#endregion

#region test pester in \dxc-deployment-automation
$pesterModule = Get-Module -Name Pester -ListAvailable | Where-Object { $_.Version -eq [version]'4.9.0' }
if (-not $pesterModule -or ($pesterModule | Measure-Object).Count -eq 0) {
    Write-Host "Pester 4.9.0 is not available. Please install it."
} else {
    $currentPester = Get-Module Pester
    if (-not $currentPester -or $currentPester.Version -ne [version]'4.9.0') {
        if ($currentPester) {
            Remove-Module Pester -Force
        }
        Import-Module Pester -MaximumVersion 4.9.0 -Force
    }
    Get-Module Pester
}

$addCfPageRuleTestPath = "C:\Source\dxc-deployment-automation\InternalModules\CloudFlareModule\Tests\Unit\Add-CFPageRule.Unit.Tests.ps1"
if (Test-Path -LiteralPath $addCfPageRuleTestPath) {
    Invoke-Pester -Path $addCfPageRuleTestPath
} else {
    Write-Warning "Add-CFPageRule unit test not found at: $addCfPageRuleTestPath"
}
$cfInteTestPath = "C:\Source\dxc-deployment-automation\InternalModules\CloudFlareModule\Tests\Integration\CloudFlareModule.Integration.Tests.ps1"
Invoke-Pester -Path $cfInteTestPath -Filter { param($t) $t.FullName -like '*Add-CFPageRule*' }
# Pester 4: compose *\Tests\Unit\* paths then feed to Invoke-Pester (no Pester filter arg)
$dxcRepoRoot = "C:\Source\dxc-deployment-automation"
$unitTestFiles = @(Get-ChildItem -Path (Join-Path $dxcRepoRoot "InternalModules\CloudFlareModule") -Recurse -Filter "*.Tests.ps1" -File | Where-Object { $_.FullName -like '*\Tests\Unit\*' })
if ($unitTestFiles.Count -gt 0) {
    Invoke-Pester -Path $unitTestFiles.FullName
} else {
    Write-Warning "No *\Tests\Unit\* test files found under: $dxcRepoRoot"
}
#endregion

#region reviewhelper pester 5
#region act
#region setup wsl
# docker desktop integration is switch on when installed wsl, but check setting -> general to make sure
wsl --intstall
wsl
#inside wsl
wsl.exe -l -v
curl -s https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash
sudo mv bin/act /usr/local/bin/
act --version
#endregion setup wsl
act -W .github/workflows/InvokeReviewHelper.yml -j invoke-review-helper -P ubuntu-latest=mcr.microsoft.com/powershell:ubuntu-22.04
#@TODO build img with git and pwsh7
#endregion act
#region docker
#switch to window container
#region create an image
# Start a long-running container
docker run -d --name review-helper-builder -v "${PWD}:/repo" -w /repo mcr.microsoft.com/powershell:ubuntu-22.04 tail -f /dev/null
# Install git and modules
docker exec review-helper-builder sh -c "apt-get update && apt-get install -y --no-install-recommends git"
docker exec review-helper-builder pwsh -NoProfile -Command "Install-Module Pester -RequiredVersion 5.5.0 -Scope CurrentUser -Force; Install-Module PSScriptAnalyzer -Scope CurrentUser -Force"
# Save as new image
docker commit review-helper-builder review-helper-runner
# Remove the temporary container
docker rm -f review-helper-builder
#endregion create an image
#lint
docker run --rm `
    -v "C:/Source/dxc-deployment-automation/:/repo" `
    -w /repo `
    review-helper-runner `
    pwsh -NoProfile -Command "./BuildScripts/Invoke-ReviewHelper.ps1"
#fix format use Invoke-Formatter
docker run --rm `
-v "C:/Source/dxc-deployment-automation/:/repo" `
    -w /repo `
    review-helper-runner `
    pwsh -NoProfile -Command "Get-ChildItem -Path /repo/InternalModules/CloudFlareModule/Tests/Add-CFSpectrumApplication.Unit.Tests.ps1 -Recurse -Filter *.ps1 -File | ForEach-Object { `$f = Invoke-Formatter -ScriptDefinition (Get-Content `$_.FullName -Raw); if (`$f) { Set-Content -Path `$_.FullName -Value `$f -NoNewline } }"

#endregion docker
#endregion reviewhelper pester 5


#region CF

#region list and filter cf account token (PAAS29486Usertoken, userCreateAdditionalTokens, accountId, abc1ZoneID from .env)
$cfUserTokenHeaders = @{ 'Authorization' = "Bearer $userCreateAdditionalTokens" }
$cfAuthTokenForListing = $userCreateAdditionalTokens   # Token with Account → "API Tokens Read"
$cfAccountId = $accountId
$cfRequiredPermissionName = 'Account Firewall Access Rules Write'   # We filter to tokens that have this

#region Dump this user token's policies (verify → get by id → output policies, no truncate)
$verifyResp = Invoke-RestMethod -Method Get -Uri 'https://api.cloudflare.com/client/v4/user/tokens/verify' -Headers $cfUserTokenHeaders -ErrorAction Stop
$cfUserTokenId = $verifyResp.result.id
$userTokenDetail = Invoke-RestMethod -Method Get -Uri "https://api.cloudflare.com/client/v4/user/tokens/$cfUserTokenId" -Headers $cfUserTokenHeaders -ErrorAction Stop
Write-Output ($userTokenDetail.result.policies | ConvertTo-Json -Depth 10 -Compress:$false)
#endregion dump user token



#region get permission_group
#region GET permission groups, filter by name to get id for "Zone Load Balancers Write" (e.g. for put token policies).
$cfPermGroupsUri = "https://api.cloudflare.com/client/v4/accounts/$accountId/tokens/permission_groups"
$permGroupsResp = Invoke-RestMethod -Method Get -Uri $cfPermGroupsUri -Headers $cfUserTokenHeaders -ErrorAction Stop
$cfPermGroups = @($permGroupsResp.result)
$cfZoneScope = 'com.cloudflare.api.account.zone'
$cfPermZone = @($cfPermGroups | Where-Object { $_.scopes -contains $cfZoneScope })
$cfPermLoadBalancerWrite = $cfPermZone | Where-Object { $_.name -like '*Load Balancer*Write*' } | Select-Object -First 1
$cfPermCustomPageRead    = $cfPermZone | Where-Object { $_.name -like '*Custom Page*Read*' } | Select-Object -First 1
Write-Host "Permission group ids (scope zone): Load Balancer Write=$($cfPermLoadBalancerWrite.id), Custom Page Read=$($cfPermCustomPageRead.id)"
# region sample response payload
# $cfZoneLBPerms = @($cfPermGroups | Where-Object { $_.name -like '*Load Balancer*' -and ($_.scope -eq 'com.cloudflare.api.account.zone' -or ($_.scopes -and $_.scopes -contains 'com.cloudflare.api.account.zone')) })
# Write-Host "Permission groups matching *Load Balancer* and scope com.cloudflare.api.account.zone: $($cfZoneLBPerms.Count)"
# $cfZoneLBPerms | ForEach-Object { Write-Output ($_ | ConvertTo-Json -Depth 10 -Compress:$false) }
# Permission groups matching *Load Balancer* and scope com.cloudflare.api.account.zone: 2
# {
#     "id":  "e9a975f628014f1d85b723993116f7d5",
#     "name":  "Load Balancers Read",
#     "description":  "Grants read access to load balancers and associated resources",
#     "scopes":  [
#                    "com.cloudflare.api.account.zone"
#                ]
# }
# {
#     "id":  "6d7f2f5f5b1d4a0e9081fdc98d432fd1",
#     "name":  "Load Balancers Write",
#     "description":  "Grants write access to load balancers and associated resources",
#     "scopes":  [
#                    "com.cloudflare.api.account.zone"
#                ]
# }
#endregion sample payload
#endregion get permission_group

#region put test granular token access policies capabilities
# put token: add two zone policies (Load Balancer Write, Custom Page Read) for zone abc1ZoneID
if ($cfPermLoadBalancerWrite -and $cfPermCustomPageRead) {
    $zoneResourceKey = "com.cloudflare.api.account.zone.$abc1ZoneID"
    # Compose new policies same shape as API (PSCustomObject) so $allPolicies serializes and displays consistently
    $resources = @{ $zoneResourceKey = '*' } | ConvertTo-Json -Compress | ConvertFrom-Json
    $newPolicyLB = [PSCustomObject]@{ effect = 'allow'; resources = $resources; permission_groups = @([PSCustomObject]@{ id = $cfPermLoadBalancerWrite.id }) }
    $newPolicyCP = [PSCustomObject]@{ effect = 'allow'; resources = $resources; permission_groups = @([PSCustomObject]@{ id = $cfPermCustomPageRead.id }) }
    $allPolicies = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $userTokenDetail.result.policies) { $allPolicies.Add($p) }
    $allPolicies.Add($newPolicyLB)
    $allPolicies.Add($newPolicyCP)
    # debug: verify composed list (all PSCustomObject => one table, 5 rows)
    Write-Host "allPolicies.Count = $($allPolicies.Count)"
    $allPolicies
    $putBody = @{ policies = $allPolicies } | ConvertTo-Json -Depth 10 -Compress:$false
    $putUri = "https://api.cloudflare.com/client/v4/user/tokens/$cfUserTokenId"
    try {
        $response = Invoke-RestMethod -Method Put -Uri $putUri -Headers $cfUserTokenHeaders -Body $putBody -ContentType 'application/json'
        if (-not $response.success) {
            throw "API call failed! The error(s) was: $(($response.errors | ForEach-Object { "Error code: $($_.code). Message: $($_.message)" }) -join '; ')"
        }
        if ($response.result) {
            $response.result | ConvertTo-Json -Depth 10 -Compress:$false | Write-Output
        }
    } catch {
        Write-Warning "API request failed. Retry attempts left: $retries. The error was $($_.Exception.Message) $cfErrorMessage"
    }

    Write-Host "put token: added zone policies (Load Balancer Write, Custom Page Read) for zone $abc1ZoneID"
} else {
    Write-Warning "Skip put: missing permission group (cfPermLoadBalancerWrite or cfPermCustomPageRead)."
}

#endregion put test granular policies

#region post new user token.
#payload
$postTokenPayload = @{ "name" = "27380-Chuong-Test-fromAPI-thenedit"; "policies" = @() }
$policy = @{
    "effect" = "allow"
    "resources" = @{ "com.cloudflare.api.account.$accountId" = "*" }
    "permission_groups" = @(@{ "id" = $cfPermLoadBalancerWrite.id })
}
$postTokenPayload["policies"] = @($policy)
$postTokenBody = $postTokenPayload | ConvertTo-Json -Depth 10 -Compress:$false
Write-Host "postTokenBody: $postTokenBody"
$tokenEndpoint = "https://api.cloudflare.com/client/v4/user/tokens"
try {
    $response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Headers $cfUserTokenHeaders -Body $postTokenBody -ContentType 'application/json'
    if (-not $response.success) {
        throw "API call failed! The error(s) was: $(($response.errors | ForEach-Object { "Error code: $($_.code). Message: $($_.message)" }) -join '; ')"
    }
    if ($response.result) {
        $response.result | ConvertTo-Json -Depth 10 -Compress:$false | Write-Output
    }
} catch {
    Write-Warning "API request failed. The error was $($_.Exception.Message) $cfErrorMessage"
}
#endregion post new user token


#region post new account token. @TODO: need super admin
#payload
$postTokenPayload = @{ "name" = "27380-Chuong-Test"; "policies" = @() }
$policy = @{
    "effect" = "allow"
    "resources" = @{ "com.cloudflare.api.account.$accountId" = "*" }
    "permission_groups" = @(@{ "id" = $lBpoolId })
}
$postTokenPayload["policies"] = @($policy)
$postTokenBody = $postTokenPayload | ConvertTo-Json -Depth 10 -Compress:$false
Write-Host "postTokenBody: $postTokenBody"
$tokenEndpoint = "https://api.cloudflare.com/client/v4/accounts/$accountId/tokens"
try {
    $response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Headers $cfUserTokenHeaders -Body $postTokenBody -ContentType 'application/json'
    if (-not $response.success) {
        throw "API call failed! The error(s) was: $(($response.errors | ForEach-Object { "Error code: $($_.code). Message: $($_.message)" }) -join '; ')"
    }
    if ($response.result) {
        $response.result | ConvertTo-Json -Depth 10 -Compress:$false | Write-Output
    }
} catch {
    Write-Warning "API request failed. Retry attempts left: $retries. The error was $($_.Exception.Message) $cfErrorMessage"
}
#endregion post new account token


if (-not $cfAuthTokenForListing -or -not $cfAccountId) {
    Write-Warning 'cfAuthTokenForListing and cfAccountId must be set; skipping fetch/filter of account tokens.'
} else {
    $cfListAccountTokensUri = "https://api.cloudflare.com/client/v4/accounts/$cfAccountId/tokens"
    $headers = @{
        'Authorization' = "Bearer $cfAuthTokenForListing"
        'Content-Type'  = 'application/json'
    }
    try {
        $listResponse = Invoke-RestMethod -Method Get -Uri $cfListAccountTokensUri -Headers $headers -ErrorAction Stop
    } catch {
        Write-Error "Failed to fetch account tokens (need token with Account → API Tokens Read for account $cfAccountId): $_"
        throw
    }
    if (-not $listResponse.success -or -not $listResponse.result) {
        Write-Warning "List account tokens response had success=$($listResponse.success) or no result."
        $tokens = @()
    } else {
        $tokens = @($listResponse.result)
    }
    if ($tokens.Count -gt 0) {
        Write-Output ($tokens[0].policies | ConvertTo-Json -Depth 10 -Compress:$false)
    }
    $filtered = @($tokens | Where-Object {
        $token = $_
        foreach ($policy in @($token.policies)) {
            foreach ($pg in @($policy.permission_groups)) {
                if ($pg.name -like "*$cfRequiredPermissionName*") { return $true }
            }
        }
        return $false
    })
    Write-Host "Account tokens with permission '$cfRequiredPermissionName': $($filtered.Count) of $($tokens.Count)"
    $filtered | ForEach-Object { Write-Host "  id=$($_.id) name=$($_.name) status=$($_.status)" }
    $script:cfAccountTokensWithFirewallAccessRulesWrite = $filtered
}
#endregion


#endregion CF