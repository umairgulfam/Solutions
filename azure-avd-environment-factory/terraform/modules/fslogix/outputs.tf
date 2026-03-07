output "profile_path" {
  value = var.storage_type == "azure_files" ? (
    "\\\\${azurerm_storage_account.files[0].name}.file.core.windows.net\\${azurerm_storage_share.profiles[0].name}"
    ) : (
    "\\\\${azurerm_netapp_volume.profiles[0].mount_ip_addresses[0]}\\${azurerm_netapp_volume.profiles[0].volume_path}"
  )
}

output "storage_account_id" {
  value = var.storage_type == "azure_files" ? azurerm_storage_account.files[0].id : null
}

