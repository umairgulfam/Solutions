output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "workspace_id" {
  value = azurerm_virtual_desktop_workspace.this.id
}

output "host_pool_ids" {
  value = { for key, pool in module.host_pool : key => pool.host_pool_id }
}

output "session_host_names" {
  value = { for key, hosts in module.session_hosts : key => hosts.vm_names }
}

output "fslogix_profile_path" {
  value = module.fslogix.profile_path
}

output "key_vault_uri" {
  value = module.key_vault.vault_uri
}

output "log_analytics_workspace_id" {
  value = module.monitoring.workspace_id
}

output "capacity_summary" {
  value = {
    profile            = var.capacity_profile
    host_pool_count    = length(local.effective_host_pools)
    session_host_count = sum([for pool in values(local.effective_host_pools) : pool.session_hosts])
    session_hosts_by_pool = {
      for key, pool in local.effective_host_pools : key => pool.session_hosts
    }
  }
}

