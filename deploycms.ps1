try {
    Import-Module C:\Source\epicloud\source\EpiCloud -Force
}
catch {
    Write-Error "Failed to import module 'EpiCloud': $_"
    exit 1
}

#C:\Source\EpiCloud\Readme.md:26
$Global:EpiCloudApiEndpointUri = 'https://paasportal.epimore.com/api/v1.0/'
#authenticate
#get client key and client secret from env variables
#this is a local test, env would be from dev.env file in same directory as this script
$devEnvPath = Join-Path $PSScriptRoot "cms.env"
if (-not (Test-Path $devEnvPath)) {
    Write-Error "dev.env file not found"
    exit 1
}
$devEnv = Get-Content $devEnvPath | ConvertFrom-StringData
$ClientKey = $devEnv.ClientKey
$ClientSecret = $devEnv.clientSecret
$projectId = $devEnv.projectId
Connect-EpiCloud -ClientKey $ClientKey -ClientSecret $ClientSecret -ProjectId $projectId

#@TODO: check provision exists


#deploy cms
#file in same directory as this script
$cmsPackageFileName = "cms.app.0.0.1.1.nupkg"
$cmsPackagePath = Join-Path $PSScriptRoot $cmsPackageFileName
if (-not (Test-Path $cmsPackagePath)) {
    Write-Error "$cmsPackagePath file not found"
    exit 1
}
$sasUrl = Get-EpiDeploymentPackageLocation
$sasUrl
#https://chngchuong1h3gz9.blob.core.windows.net/deploymentpackages?sv=2023-01-03&st=2026-01-30T09:43:16Z&se=2026-01-31T09:48:16Z&sr=c&sp=w&sig=L6N5DCTPQQGMmjIq3A%2FZwd%2FHhX7XgNixlSlbyAwA2kk%3D

# Using common cmdlet arguments like -Verbose or -Debug will not provide upload speed out of the box.
# They provide diagnostic information about command execution, not transfer metrics like speed or duration.
# To inspect upload speed, you must manually measure the time and file size like shown below:

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Add-EpiDeploymentPackage -SasUrl $sasUrl -Path $cmsPackagePath -Verbose
$stopwatch.Stop()

$fileSizeBytes = (Get-Item $cmsPackagePath).Length
$fileSizeMB = [Math]::Round($fileSizeBytes / 1MB, 2)
$speedMbps = [Math]::Round(($fileSizeBytes * 8) / ($stopwatch.Elapsed.TotalSeconds * 1024 * 1024),2)

Write-Host "Upload completed in $($stopwatch.Elapsed.TotalSeconds) seconds."
Write-Host "File size: $fileSizeMB MB"
Write-Host "Average upload speed: $speedMbps Mbps"
#check lease id - not possible due to authorization issue 1. sas url is write-only and 2. we only have paas middleware credentials, so no context for Get-AzStorageBlob
# Get Blob Properties
# The SAS Url from Get-EpiDeploymentPackageLocation includes the full URI to the deployed blob.
# We'll use the Azure.Storage.Blobs REST API via Invoke-RestMethod for a general purpose approach.
# Extract the blob URL (strip any query parameters for the properties endpoint)
# $blobUri = $sasUrl
# if ($blobUri -is [string]) {
#     $blobUri = [uri]$blobUri
# }
# $baseBlobUrl = $blobUri.GetLeftPart([System.UriPartial]::Path)
# $queryString = $blobUri.Query
# Construct the Uri for blob properties using the SAS token
# $propertiesUri = $sasUrl
# try {
#     # Retrieve blob properties using HEAD request.
#     # Note: The SAS from Get-EpiDeploymentPackageLocation is for uploads (write-only).
#     # If it has no read permission, HEAD will return 403; we treat that as "properties not available" instead of failing.
#     $response = Invoke-WebRequest -Uri $propertiesUri -Method Head
#     Write-Host "Blob Properties:"
#     foreach ($key in $response.Headers.Keys) {
#         if ($key -like "x-ms-*") {
#             Write-Host "$key : $($response.Headers[$key])"
#         }
#     }
# } catch {
#     $statusCode = $_.Exception.Response?.StatusCode?.value__
#     if ($statusCode -eq 403) {
#         Write-Warning "Blob properties unavailable: the SAS from Get-EpiDeploymentPackageLocation is write-only (no read permission). Lease and other properties cannot be read with this URL."
#     }
#     else {
#         Write-Error "Failed to retrieve blob properties: $($_.Exception.Message)"
#     }
# }

#backup chngchuong1h3gz9inte
#APPLICATIONINSIGHTS_CONNECTION_STRING
#InstrumentationKey=007d95e1-4899-4114-b025-0ef1ff1338be;IngestionEndpoint=https://northeurope-2.in.applicationinsights.azure.com/;LiveEndpoint=https://northeurope.livediagnostics.monitor.azure.com/;ApplicationId=a24d3343-3a49-43a1-9bf4-f645ebc02733

#deploy blob
Start-EpiDeployment -DeploymentPackage $cmsPackageFileName -TargetEnvironment "Integration" -DirectDeploy
