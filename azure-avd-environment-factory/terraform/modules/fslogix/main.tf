resource "azurerm_storage_account" "files" {
  count = var.storage_type == "azure_files" ? 1 : 0

  name                            = substr("st${var.name_prefix}profiles", 0, 24)
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Premium"
  account_replication_type        = "LRS"
  account_kind                    = "FileStorage"
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = !var.private_only_data_plane
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true
  tags                            = var.tags

  azure_files_authentication {
    directory_type = var.azure_files_directory_type

    dynamic "active_directory" {
      for_each = var.azure_files_directory_type == "AD" && var.azure_files_active_directory != null ? [var.azure_files_active_directory] : []
      content {
        domain_name         = active_directory.value.domain_name
        domain_guid         = active_directory.value.domain_guid
        domain_sid          = active_directory.value.domain_sid
        storage_sid         = active_directory.value.storage_sid
        forest_name         = active_directory.value.forest_name
        netbios_domain_name = active_directory.value.netbios_domain_name
      }
    }
  }
}

resource "azurerm_storage_share" "profiles" {
  count = var.storage_type == "azure_files" ? 1 : 0

  name               = "profiles"
  storage_account_id = azurerm_storage_account.files[0].id
  quota              = var.share_quota_gb
  enabled_protocol   = "SMB"
}

resource "azurerm_role_assignment" "profile_contributor" {
  for_each = var.storage_type == "azure_files" ? var.profile_principal_ids : toset([])

  scope                = azurerm_storage_account.files[0].id
  role_definition_name = "Storage File Data SMB Share Contributor"
  principal_id         = each.value
}

resource "azurerm_private_dns_zone" "file" {
  count = var.storage_type == "azure_files" && var.enable_private_endpoint ? 1 : 0

  name                = "privatelink.file.core.windows.net"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "file" {
  count = var.storage_type == "azure_files" && var.enable_private_endpoint ? 1 : 0

  name                  = "link-${var.name_prefix}-file"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.file[0].name
  virtual_network_id    = var.vnet_id
}

resource "azurerm_private_endpoint" "file" {
  count = var.storage_type == "azure_files" && var.enable_private_endpoint ? 1 : 0

  name                = "pe-${var.name_prefix}-profiles"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name_prefix}-profiles"
    private_connection_resource_id = azurerm_storage_account.files[0].id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.file[0].id]
  }
}

resource "azurerm_netapp_account" "this" {
  count = var.storage_type == "anf" ? 1 : 0

  name                = "anf-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  dynamic "active_directory" {
    for_each = var.anf_active_directory == null ? [] : [var.anf_active_directory]
    content {
      dns_servers         = active_directory.value.dns_servers
      domain              = active_directory.value.domain
      smb_server_name     = active_directory.value.smb_server_name
      username            = active_directory.value.username
      password            = active_directory.value.password
      organizational_unit = active_directory.value.organizational_unit
    }
  }
}

resource "azurerm_netapp_pool" "this" {
  count = var.storage_type == "anf" ? 1 : 0

  name                = "pool-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  account_name        = azurerm_netapp_account.this[0].name
  service_level       = "Premium"
  size_in_tb          = 4
}

resource "azurerm_netapp_volume" "profiles" {
  count = var.storage_type == "anf" ? 1 : 0

  name                = "profiles"
  location            = var.location
  resource_group_name = var.resource_group_name
  account_name        = azurerm_netapp_account.this[0].name
  pool_name           = azurerm_netapp_pool.this[0].name
  volume_path         = "profiles"
  service_level       = "Premium"
  subnet_id           = var.anf_subnet_id
  storage_quota_in_gb = max(var.share_quota_gb, 100)
  protocols           = ["CIFS"]
  security_style      = "ntfs"
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = var.storage_type != "anf" || var.share_quota_gb >= 100
      error_message = "ANF profile volumes require at least 100 GiB."
    }
  }
}
