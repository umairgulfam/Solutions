mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000001"
  tenant_id       = "00000000-0000-0000-0000-000000000002"
  name_prefix     = "test"
  admin_password  = "Test-Only-Password-Do-Not-Use-123!"
}

run "small_profile" {
  command = plan

  variables {
    capacity_profile = "small"
  }

  assert {
    condition     = length(local.effective_host_pools) == 4
    error_message = "The small profile must create four host pools."
  }

  assert {
    condition     = sum([for pool in values(local.effective_host_pools) : pool.session_hosts]) == 4
    error_message = "The small profile must create four session hosts."
  }
}

run "medium_profile" {
  command = plan

  variables {
    capacity_profile = "medium"
  }

  assert {
    condition     = length(local.effective_host_pools) == 4
    error_message = "The medium profile must create four host pools."
  }

  assert {
    condition     = sum([for pool in values(local.effective_host_pools) : pool.session_hosts]) == 12
    error_message = "The medium profile must create twelve session hosts."
  }
}

run "large_profile" {
  command = plan

  variables {
    capacity_profile = "large"
  }

  assert {
    condition     = length(local.effective_host_pools) == 6
    error_message = "The large profile must create six host pools."
  }

  assert {
    condition     = sum([for pool in values(local.effective_host_pools) : pool.session_hosts]) == 30
    error_message = "The large profile must create thirty session hosts."
  }
}

run "custom_profile" {
  command = plan

  variables {
    capacity_profile = "custom"
    host_pools = {
      engineering = {
        session_hosts = 2
        vm_size       = "Standard_D4s_v5"
      }
      operations = {
        session_hosts = 3
        vm_size       = "Standard_D8s_v5"
      }
    }
  }

  assert {
    condition     = length(local.effective_host_pools) == 2
    error_message = "The custom profile must preserve the supplied pool count."
  }

  assert {
    condition     = sum([for pool in values(local.effective_host_pools) : pool.session_hosts]) == 5
    error_message = "The custom profile must preserve per-pool session-host counts."
  }
}
