#Requires -Version 5.1

<#
    AvdPatch module loader.

    Dot-sources Private then Public so public functions can call private helpers.
    Only Public functions are exported; the manifest lists them explicitly so
    the module surface is reviewable in one place.
#>

Set-StrictMode -Version Latest

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private/*.ps1') -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public/*.ps1')  -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to load $($file.FullName): $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function @(
    # Catalog
    'Get-PatchTuesday'
    'Get-PatchCycleTag'
    'ConvertFrom-MsCatalogHtml'
    'Find-MsCatalogUpdate'
    'Get-MsCatalogDownloadUrl'
    'Select-BestCatalogUpdate'
    'Save-CatalogFile'
    'Get-CleanCellText'
    # Storage
    'Get-AzureImdsToken'
    'Get-BlobUri'
    'Get-BlobText'
    'Save-BlobToFile'
    'Set-BlobFromFile'
    'Set-BlobFromText'
    'Test-BlobExists'
    # Patching
    'Get-SessionHostOsIdentity'
    'Test-KbInstalled'
    'Select-ManifestEntry'
    'Test-UpdateApplicable'
    'Get-FileSha256'
    'Test-FileIntegrity'
    'Get-DismExitCodeInfo'
    'Install-MsuPackage'
    'Test-PendingReboot'
    # Logging
    'Initialize-PatchLog'
    'Write-PatchLog'
)
