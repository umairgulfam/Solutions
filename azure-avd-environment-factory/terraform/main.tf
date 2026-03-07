data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

data "azuread_service_principal" "avd" {
  client_id = "9cdead84-a844-4324-93f2-b2e6bb768d07"
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.base_name}-avd"
  location = var.location
  tags     = local.common_tags
}

resource "random_password" "local_admin" {
  count            = var.admin_password == null ? 1 : 0
  length           = 24
  special          = true
  override_special = "!@#%_-"
}

locals {
  effective_admin_password = var.admin_password != null ? var.admin_password : random_password.local_admin[0].result
}

module "networking" {
  source = "./modules/networking"

  name_prefix                      = local.base_name
  location                         = var.location
  resource_group_name              = azurerm_resource_group.this.name
  vnet_address_space               = var.vnet_address_space
  session_host_subnet_prefixes     = var.session_host_subnet_prefixes
  private_endpoint_subnet_prefixes = var.private_endpoint_subnet_prefixes
  anf_subnet_prefixes              = var.anf_subnet_prefixes
  dns_servers                      = var.dns_servers
  tags                             = local.common_tags
}

module "monitoring" {
  source = "./modules/monitoring"

  name_prefix         = local.base_name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.common_tags
}

module "key_vault" {
  source = "./modules/key-vault"

  name_prefix                = replace(local.base_name, "-", "")
  location                   = var.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = var.tenant_id
  current_principal_id       = data.azurerm_client_config.current.object_id
  admin_username             = var.admin_username
  admin_password             = local.effective_admin_password
  enable_private_endpoint    = var.enable_private_endpoints
  private_only_data_plane    = var.private_only_data_plane
  private_endpoint_subnet_id = module.networking.private_endpoint_subnet_id
  vnet_id                    = module.networking.vnet_id
  tags                       = local.common_tags
}

module "fslogix" {
  source = "./modules/fslogix"

  name_prefix                  = replace(local.base_name, "-", "")
  location                     = var.location
  resource_group_name          = azurerm_resource_group.this.name
  storage_type                 = var.fslogix_storage_type
  share_quota_gb               = var.fslogix_share_quota_gb
  anf_subnet_id                = module.networking.anf_subnet_id
  private_endpoint_subnet_id   = module.networking.private_endpoint_subnet_id
  vnet_id                      = module.networking.vnet_id
  enable_private_endpoint      = var.enable_private_endpoints
  private_only_data_plane      = var.private_only_data_plane
  azure_files_directory_type   = var.azure_files_directory_type
  azure_files_active_directory = var.azure_files_active_directory
  profile_principal_ids        = var.rbac.desktop_user_principal_ids
  anf_active_directory         = var.anf_active_directory
  tags                         = local.common_tags
}

resource "azurerm_virtual_desktop_workspace" "this" {
  name                = "vdws-${local.base_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  friendly_name       = "${upper(var.environment)} AVD Workspace"
  description         = "Managed by Azure AVD Environment Factory"
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "avd_autoscale" {
  count = anytrue([
    for pool in values(local.effective_host_pools) : pool.scaling_enabled && pool.type == "Pooled"
  ]) ? 1 : 0

  scope                            = data.azurerm_subscription.current.id
  role_definition_name             = "Desktop Virtualization Power On Off Contributor"
  principal_id                     = data.azuread_service_principal.avd.object_id
  skip_service_principal_aad_check = true
}

module "host_pool" {
  for_each = local.effective_host_pools
  source   = "./modules/avd-host-pool"

  name_prefix                = local.base_name
  pool_key                   = each.key
  location                   = var.location
  resource_group_name        = azurerm_resource_group.this.name
  workspace_id               = azurerm_virtual_desktop_workspace.this.id
  type                       = each.value.type
  load_balancer_type         = each.value.load_balancer_type
  personal_assignment_type   = each.value.personal_assignment_type
  maximum_sessions_allowed   = each.value.max_sessions
  session_host_count         = each.value.session_hosts
  scaling_enabled            = each.value.scaling_enabled
  scaling_timezone           = each.value.scaling_timezone
  peak_start_time            = each.value.peak_start_time
  peak_end_time              = each.value.peak_end_time
  peak_minimum_hosts_percent = each.value.peak_minimum_hosts_pct
  off_peak_minimum_hosts     = each.value.off_peak_minimum_hosts
  log_analytics_workspace_id = module.monitoring.workspace_id
  tags                       = merge(local.common_tags, each.value.tags)

  depends_on = [azurerm_role_assignment.avd_autoscale]
}

module "session_hosts" {
  for_each = local.effective_host_pools
  source   = "./modules/session-host"

  name_prefix                  = local.base_name
  pool_key                     = each.key
  host_pool_name               = module.host_pool[each.key].host_pool_name
  location                     = var.location
  resource_group_name          = azurerm_resource_group.this.name
  session_host_count           = each.value.session_hosts
  vm_size                      = each.value.vm_size
  zone                         = each.value.zone
  subnet_id                    = module.networking.session_host_subnet_id
  host_pool_registration_token = module.host_pool[each.key].registration_token
  admin_username               = var.admin_username
  admin_password               = local.effective_admin_password
  join_type                    = var.join_type
  tenant_id                    = var.tenant_id
  domain_name                  = var.domain_name
  domain_ou_path               = var.domain_ou_path
  domain_join_username         = var.domain_join_username
  domain_join_password         = var.domain_join_password
  image_id                     = each.value.image_id
  image_publisher              = each.value.image_publisher
  image_offer                  = each.value.image_offer
  image_sku                    = each.value.image_sku
  image_version                = each.value.image_version
  log_analytics_workspace_id   = module.monitoring.workspace_id
  data_collection_rule_id      = module.monitoring.data_collection_rule_id
  shutdown_enabled             = each.value.shutdown_enabled
  shutdown_time                = each.value.shutdown_time
  shutdown_timezone            = each.value.scaling_timezone
  tags                         = merge(local.common_tags, each.value.tags)
}

locals {
  desktop_assignments = merge([
    for pool_key, pool in module.host_pool : {
      for principal_id in var.rbac.desktop_user_principal_ids :
      "${pool_key}-${principal_id}" => {
        scope        = pool.desktop_application_group_id
        principal_id = principal_id
      }
    }
  ]...)

  admin_assignments = {
    for principal_id in var.rbac.admin_principal_ids : principal_id => {
      scope        = azurerm_resource_group.this.id
      principal_id = principal_id
    }
  }
}

resource "azurerm_role_assignment" "desktop_user" {
  for_each = local.desktop_assignments

  scope                = each.value.scope
  role_definition_name = "Desktop Virtualization User"
  principal_id         = each.value.principal_id
}

resource "azurerm_role_assignment" "admin" {
  for_each = local.admin_assignments

  scope                = each.value.scope
  role_definition_name = "Desktop Virtualization Contributor"
  principal_id         = each.value.principal_id
}

resource "azurerm_consumption_budget_resource_group" "this" {
  count = var.monthly_budget_amount > 0 ? 1 : 0

  name              = "budget-${local.base_name}-avd"
  resource_group_id = azurerm_resource_group.this.id
  amount            = var.monthly_budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00'Z'", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_contact_emails
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}

check "custom_pool_required" {
  assert {
    condition     = var.capacity_profile != "custom" || length(var.host_pools) > 0
    error_message = "Define at least one host_pool when capacity_profile is custom."
  }
}

check "active_directory_inputs" {
  assert {
    condition = var.join_type != "active_directory" || (
      var.domain_name != "" && var.domain_join_username != "" && var.domain_join_password != ""
    )
    error_message = "AD DS join requires domain_name, domain_join_username, and domain_join_password."
  }
}

check "anf_active_directory_inputs" {
  assert {
    condition     = var.fslogix_storage_type != "anf" || var.anf_active_directory != null
    error_message = "ANF SMB profiles require anf_active_directory configuration."
  }
}

check "azure_files_active_directory_inputs" {
  assert {
    condition = var.fslogix_storage_type != "azure_files" || (
      var.azure_files_directory_type != "AD" || var.azure_files_active_directory != null
    )
    error_message = "Azure Files with AD directory type requires azure_files_active_directory."
  }
}

check "private_network_inputs" {
  assert {
    condition     = !var.private_only_data_plane || var.enable_private_endpoints
    error_message = "private_only_data_plane requires enable_private_endpoints=true."
  }
}
