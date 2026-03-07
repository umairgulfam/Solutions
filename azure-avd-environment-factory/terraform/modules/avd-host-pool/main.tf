resource "azurerm_virtual_desktop_host_pool" "this" {
  name                             = "vdpool-${var.name_prefix}-${var.pool_key}"
  location                         = var.location
  resource_group_name              = var.resource_group_name
  type                             = var.type
  load_balancer_type               = var.type == "Personal" ? "Persistent" : var.load_balancer_type
  personal_desktop_assignment_type = var.type == "Personal" ? var.personal_assignment_type : null
  maximum_sessions_allowed         = var.type == "Pooled" ? var.maximum_sessions_allowed : null
  start_vm_on_connect              = true
  validate_environment             = false
  custom_rdp_properties            = "audiocapturemode:i:1;redirectclipboard:i:1;redirectprinters:i:1;"
  tags                             = var.tags
}

resource "time_rotating" "registration" {
  rotation_days = 29
}

resource "azurerm_virtual_desktop_host_pool_registration_info" "this" {
  hostpool_id     = azurerm_virtual_desktop_host_pool.this.id
  expiration_date = timeadd(time_rotating.registration.id, "720h")
}

resource "azurerm_virtual_desktop_application_group" "desktop" {
  name                = "vdag-${var.name_prefix}-${var.pool_key}-desktop"
  location            = var.location
  resource_group_name = var.resource_group_name
  type                = "Desktop"
  host_pool_id        = azurerm_virtual_desktop_host_pool.this.id
  friendly_name       = "${upper(var.pool_key)} Desktop"
  tags                = var.tags
}

resource "azurerm_virtual_desktop_workspace_application_group_association" "this" {
  workspace_id         = var.workspace_id
  application_group_id = azurerm_virtual_desktop_application_group.desktop.id
}

resource "azurerm_virtual_desktop_scaling_plan" "this" {
  count = var.scaling_enabled && var.type == "Pooled" ? 1 : 0

  name                = "vdsp-${var.name_prefix}-${var.pool_key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  time_zone           = var.scaling_timezone
  friendly_name       = "${upper(var.pool_key)} autoscale"
  tags                = var.tags

  schedule {
    name                               = "weekday"
    days_of_week                       = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
    ramp_up_start_time                 = var.peak_start_time
    ramp_up_load_balancing_algorithm   = "BreadthFirst"
    ramp_up_minimum_hosts_percent      = var.peak_minimum_hosts_percent
    ramp_up_capacity_threshold_percent = 80
    peak_start_time                    = var.peak_start_time
    peak_load_balancing_algorithm      = "BreadthFirst"
    ramp_down_start_time               = var.peak_end_time
    ramp_down_load_balancing_algorithm = "DepthFirst"
    ramp_down_minimum_hosts_percent = var.session_host_count == 0 ? 0 : min(
      100,
      ceil(var.off_peak_minimum_hosts / var.session_host_count * 100)
    )
    ramp_down_force_logoff_users         = false
    ramp_down_wait_time_minutes          = 30
    ramp_down_notification_message       = "This session host is scaling down. Save your work and sign out."
    ramp_down_capacity_threshold_percent = 50
    ramp_down_stop_hosts_when            = "ZeroSessions"
    off_peak_start_time                  = var.peak_end_time
    off_peak_load_balancing_algorithm    = "DepthFirst"
  }
}

resource "azurerm_virtual_desktop_scaling_plan_host_pool_association" "this" {
  count = var.scaling_enabled && var.type == "Pooled" ? 1 : 0

  host_pool_id    = azurerm_virtual_desktop_host_pool.this.id
  scaling_plan_id = azurerm_virtual_desktop_scaling_plan.this[0].id
  enabled         = true
}

resource "azurerm_monitor_diagnostic_setting" "host_pool" {
  name                       = "diag-${var.pool_key}-hostpool"
  target_resource_id         = azurerm_virtual_desktop_host_pool.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "Checkpoint" }
  enabled_log { category = "Error" }
  enabled_log { category = "Management" }
  enabled_log { category = "Connection" }
  enabled_log { category = "HostRegistration" }
  enabled_log { category = "AgentHealthStatus" }
}
