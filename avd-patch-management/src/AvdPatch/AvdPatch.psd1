@{
    RootModule        = 'AvdPatch.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b7e4c1a2-9f38-4d5e-8c71-3a6d2e5f9b04'
    Author            = 'AVD Patch Management contributors'
    CompanyName       = 'Unknown'
    Copyright         = '(c) 2026. MIT licensed.'
    Description       = 'Shared functions for downloading Microsoft Update Catalog patches to Azure Storage and installing them on Azure Virtual Desktop session hosts.'

    # 5.1 so the installer runs on session hosts with no extra runtime installed.
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-PatchTuesday'
        'Get-PatchCycleTag'
        'ConvertFrom-MsCatalogHtml'
        'Find-MsCatalogUpdate'
        'Get-MsCatalogDownloadUrl'
        'Select-BestCatalogUpdate'
        'Save-CatalogFile'
        'Get-CleanCellText'
        'Get-AzureImdsToken'
        'Get-BlobUri'
        'Get-BlobText'
        'Save-BlobToFile'
        'Set-BlobFromFile'
        'Set-BlobFromText'
        'Test-BlobExists'
        'Get-SessionHostOsIdentity'
        'Test-KbInstalled'
        'Select-ManifestEntry'
        'Test-UpdateApplicable'
        'Get-FileSha256'
        'Test-FileIntegrity'
        'Get-DismExitCodeInfo'
        'Install-MsuPackage'
        'Test-PendingReboot'
        'Initialize-PatchLog'
        'Write-PatchLog'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('AVD', 'AzureVirtualDesktop', 'Patching', 'WindowsUpdate', 'Azure')
            LicenseUri = 'https://github.com/your-org/avd-patch-management/blob/main/LICENSE'
            ProjectUri = 'https://github.com/your-org/avd-patch-management'
        }
    }
}
