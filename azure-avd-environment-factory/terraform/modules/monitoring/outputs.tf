output "workspace_id" { value = azurerm_log_analytics_workspace.this.id }
output "data_collection_rule_id" { value = azurerm_monitor_data_collection_rule.windows.id }

