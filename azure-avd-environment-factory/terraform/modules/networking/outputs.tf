output "vnet_id" { value = azurerm_virtual_network.this.id }
output "session_host_subnet_id" { value = azurerm_subnet.session_hosts.id }
output "private_endpoint_subnet_id" { value = azurerm_subnet.private_endpoints.id }
output "anf_subnet_id" { value = azurerm_subnet.anf.id }
