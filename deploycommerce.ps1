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
$devEnvPath = Join-Path $PSScriptRoot "commerce.env"
if (-not (Test-Path $devEnvPath)) {
    Write-Error "commerce.env file not found"
    exit 1
}
$devEnv = Get-Content $devEnvPath | ConvertFrom-StringData
$ClientKey = $devEnv.ClientKey
$ClientSecret = $devEnv.clientSecret
$projectId = $devEnv.projectId
Connect-EpiCloud -ClientKey $ClientKey -ClientSecret $ClientSecret -ProjectId $projectId

#APPLICATIONINSIGHTS_CONNECTION_STRING
#InstrumentationKey=a049c66c-c8d5-45bb-989d-40bb3e23993c;IngestionEndpoint=https://northeurope-2.in.applicationinsights.azure.com/;LiveEndpoint=https://northeurope.livediagnostics.monitor.azure.com/;ApplicationId=03c662bd-0208-46a8-adc1-81bdeb5ab0eb

#ade1:
#WFNpxqa2JgfyAQgum2VhTo3a5IpOWe205U3eKXcgTg4xq1cE
#RdjpaS+52wf+ac72byhFsxhj0EXNGRky4TpcxtEf59KyzRQLTdUa1T2Wv5NBRGGg


#deploy code
#file in same directory as this script
$commercePackageFileName = "commerce.cms.app.0.0.5.nupkg"
$commercePackagePath = Join-Path $PSScriptRoot $commercePackageFileName
if (-not (Test-Path $commercePackagePath)) {
    Write-Error "$commercePackagePath file not found"
    exit 1
}
$sasUrl = Get-EpiDeploymentPackageLocation
$sasUrl
#file nhe https://chngcommerc99sab.blob.core.windows.net/deploymentpackages?sv=2023-01-03&st=2026-01-30T10:19:29Z&se=2026-01-31T10:24:29Z&sr=c&sp=w&sig=N8B6jVaybWyTifBIcJtLmF5%2FskY20MPBtMQcjjqDWR8%3D
#file nang: https://chngcommerc99sab.blob.core.windows.net/deploymentpackages?sv=2023-01-03&st=2026-01-30T12:44:37Z&se=2026-01-31T12:49:37Z&sr=c&sp=w&sig=5KkgKucYaQm1nL%2Bk9g4SgKzeacPxV0LHA%2FFmZboXj1Y%3D


#foundation:

# Using common cmdlet arguments like -Verbose or -Debug will not provide upload speed out of the box.
# They provide diagnostic information about command execution, not transfer metrics like speed or duration.
# To inspect upload speed, you must manually measure the time and file size like shown below:

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Add-EpiDeploymentPackage -SasUrl $sasUrl -Path $commercePackagePath -Verbose
$stopwatch.Stop()

$fileSizeBytes = (Get-Item $commercePackagePath).Length
$fileSizeMB = [Math]::Round($fileSizeBytes / 1MB, 2)
$speedMbps = [Math]::Round(($fileSizeBytes * 8) / ($stopwatch.Elapsed.TotalSeconds * 1024 * 1024),2)

Write-Host "Upload completed in $($stopwatch.Elapsed.TotalSeconds) seconds."
Write-Host "File size: $fileSizeMB MB"
Write-Host "Average upload speed: $speedMbps Mbps"

#deploy blob
Start-EpiDeployment -DeploymentPackage $commercePackageFileName -TargetEnvironment "ADE1"
# Get-EpiDeployment -ProjectId $projectId -Id "87aad070-00db-4148-8a3c-b3e5009b6a61"
Complete-EpiDeployment -ProjectId $projectId -Id "87aad070-00db-4148-8a3c-b3e5009b6a61"
