locals {
  common_tags = merge(var.tags, {
    environment = var.environment
    solution    = "avd-environment-factory"
  })

  capacity_profiles = {
    small = {
      dev        = { session_hosts = 1, vm_size = "Standard_D2s_v5" }
      qa         = { session_hosts = 1, vm_size = "Standard_D2s_v5" }
      prod-us    = { session_hosts = 1, vm_size = "Standard_D4s_v5" }
      operations = { session_hosts = 1, vm_size = "Standard_D2s_v5" }
    }
    medium = {
      dev        = { session_hosts = 3, vm_size = "Standard_D4s_v5" }
      qa         = { session_hosts = 3, vm_size = "Standard_D4s_v5" }
      prod-us    = { session_hosts = 3, vm_size = "Standard_D4s_v5" }
      operations = { session_hosts = 3, vm_size = "Standard_D4s_v5" }
    }
    large = {
      dev         = { session_hosts = 5, vm_size = "Standard_D8s_v5" }
      qa          = { session_hosts = 5, vm_size = "Standard_D8s_v5" }
      prod-us     = { session_hosts = 5, vm_size = "Standard_D8s_v5" }
      prod-eu     = { session_hosts = 5, vm_size = "Standard_D8s_v5" }
      finance     = { session_hosts = 5, vm_size = "Standard_D8s_v5" }
      contractors = { session_hosts = 5, vm_size = "Standard_D8s_v5" }
    }
  }

  profile_host_pools = var.capacity_profile == "custom" ? {} : {
    for key, pool in local.capacity_profiles[var.capacity_profile] : key => merge({
      type                     = "Pooled"
      load_balancer_type       = "BreadthFirst"
      personal_assignment_type = "Automatic"
      max_sessions             = 16
      image_id                 = null
      image_publisher          = "MicrosoftWindowsDesktop"
      image_offer              = "windows-11"
      image_sku                = "win11-23h2-avd"
      image_version            = "latest"
      zone                     = null
      scaling_enabled          = true
      scaling_timezone         = "UTC"
      peak_start_time          = "07:00"
      peak_end_time            = "19:00"
      peak_minimum_hosts_pct   = 20
      off_peak_minimum_hosts   = 0
      shutdown_enabled         = false
      shutdown_time            = "22:00"
      tags                     = {}
    }, pool)
  }

  effective_host_pools = var.capacity_profile == "custom" ? var.host_pools : local.profile_host_pools
  base_name            = "${var.name_prefix}-${var.environment}"
}

