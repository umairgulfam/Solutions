output "vm_ids" { value = azurerm_windows_virtual_machine.this[*].id }
output "vm_names" { value = azurerm_windows_virtual_machine.this[*].name }

