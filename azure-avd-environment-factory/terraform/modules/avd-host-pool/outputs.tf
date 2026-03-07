output "host_pool_id" { value = azurerm_virtual_desktop_host_pool.this.id }
output "host_pool_name" { value = azurerm_virtual_desktop_host_pool.this.name }
output "desktop_application_group_id" { value = azurerm_virtual_desktop_application_group.desktop.id }
output "registration_token" {
  value     = azurerm_virtual_desktop_host_pool_registration_info.this.token
  sensitive = true
}
