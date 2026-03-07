resource "azurerm_key_vault" "this" {
  name                          = substr("kv${var.name_prefix}avd", 0, 24)
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  enable_rbac_authorization     = true
  soft_delete_retention_days    = 7
  purge_protection_enabled      = true
  public_network_access_enabled = !var.private_only_data_plane
  tags                          = var.tags
}

resource "azurerm_role_assignment" "deployer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.current_principal_id
}

resource "azurerm_key_vault_secret" "admin_username" {
  name         = "session-host-admin-username"
  value        = var.admin_username
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.deployer]
}

resource "azurerm_key_vault_secret" "admin_password" {
  name         = "session-host-admin-password"
  value        = var.admin_password
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.deployer]
}

resource "azurerm_private_dns_zone" "vault" {
  count = var.enable_private_endpoint ? 1 : 0

  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "vault" {
  count = var.enable_private_endpoint ? 1 : 0

  name                  = "link-${var.name_prefix}-vault"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.vault[0].name
  virtual_network_id    = var.vnet_id
}

resource "azurerm_private_endpoint" "vault" {
  count = var.enable_private_endpoint ? 1 : 0

  name                = "pe-${var.name_prefix}-vault"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name_prefix}-vault"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.vault[0].id]
  }
}
