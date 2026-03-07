locals {
  vm_names = [
    for index in range(var.session_host_count) :
    format(
      "v%s%s%s%02d",
      substr(replace(var.name_prefix, "-", ""), 0, 6),
      substr(replace(var.pool_key, "-", ""), 0, 4),
      substr(md5(var.pool_key), 0, 2),
      index + 1
    )
  ]
}

resource "azurerm_network_interface" "this" {
  count = var.session_host_count

  name                = "nic-${local.vm_names[count.index]}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "this" {
  count = var.session_host_count

  name                  = local.vm_names[count.index]
  computer_name         = local.vm_names[count.index]
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = var.vm_size
  zone                  = var.zone
  network_interface_ids = [azurerm_network_interface.this[count.index].id]
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  secure_boot_enabled   = true
  vtpm_enabled          = true
  patch_assessment_mode = "AutomaticByPlatform"
  patch_mode            = "AutomaticByOS"
  license_type          = "Windows_Client"
  source_image_id       = var.image_id
  tags                  = var.tags

  dynamic "source_image_reference" {
    for_each = var.image_id == null ? [1] : []
    content {
      publisher = var.image_publisher
      offer     = var.image_offer
      sku       = var.image_sku
      version   = var.image_version
    }
  }

  os_disk {
    name                 = "osdisk-${local.vm_names[count.index]}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  identity { type = "SystemAssigned" }
}

resource "azurerm_virtual_machine_extension" "entra_join" {
  count = var.join_type == "entra" ? var.session_host_count : 0

  name                       = "AADLoginForWindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.this[count.index].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "2.2"
  auto_upgrade_minor_version = true

  settings = jsonencode({ mdmId = "0000000a-0000-0000-c000-000000000000" })
}

resource "azurerm_virtual_machine_extension" "domain_join" {
  count = var.join_type == "active_directory" ? var.session_host_count : 0

  name                       = "JsonADDomainExtension"
  virtual_machine_id         = azurerm_windows_virtual_machine.this[count.index].id
  publisher                  = "Microsoft.Compute"
  type                       = "JsonADDomainExtension"
  type_handler_version       = "1.3"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    Name    = var.domain_name
    OUPath  = var.domain_ou_path
    User    = var.domain_join_username
    Restart = true
    Options = 3
  })
  protected_settings = jsonencode({ Password = var.domain_join_password })
}

resource "azurerm_virtual_machine_extension" "avd_agent" {
  count = var.session_host_count

  name                       = "DSC"
  virtual_machine_id         = azurerm_windows_virtual_machine.this[count.index].id
  publisher                  = "Microsoft.Powershell"
  type                       = "DSC"
  type_handler_version       = "2.83"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    modulesUrl            = "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02714.342.zip"
    configurationFunction = "Configuration.ps1\\AddSessionHost"
    properties = {
      hostPoolName = var.host_pool_name
      aadJoin      = var.join_type == "entra"
    }
  })
  protected_settings = jsonencode({
    properties = { registrationInfoToken = var.host_pool_registration_token }
  })

  depends_on = [
    azurerm_virtual_machine_extension.entra_join,
    azurerm_virtual_machine_extension.domain_join
  ]
}

resource "azurerm_virtual_machine_extension" "azure_monitor_agent" {
  count = var.session_host_count

  name                       = "AzureMonitorWindowsAgent"
  virtual_machine_id         = azurerm_windows_virtual_machine.this[count.index].id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorWindowsAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
}

resource "azurerm_monitor_data_collection_rule_association" "this" {
  count = var.session_host_count

  name                    = "dcra-${local.vm_names[count.index]}"
  target_resource_id      = azurerm_windows_virtual_machine.this[count.index].id
  data_collection_rule_id = var.data_collection_rule_id

  depends_on = [azurerm_virtual_machine_extension.azure_monitor_agent]
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "this" {
  count = var.shutdown_enabled ? var.session_host_count : 0

  virtual_machine_id    = azurerm_windows_virtual_machine.this[count.index].id
  location              = var.location
  enabled               = true
  daily_recurrence_time = replace(var.shutdown_time, ":", "")
  timezone              = var.shutdown_timezone

  notification_settings { enabled = false }
  tags = var.tags
}
