resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name_prefix}-avd"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_monitor_data_collection_rule" "windows" {
  name                = "dcr-${var.name_prefix}-windows"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.this.id
      name                  = "central-law"
    }
  }

  data_flow {
    streams      = ["Microsoft-InsightsMetrics"]
    destinations = ["central-law"]
  }

  data_sources {
    performance_counter {
      name                          = "avd-performance"
      streams                       = ["Microsoft-InsightsMetrics"]
      sampling_frequency_in_seconds = 60
      counter_specifiers = [
        "\\Processor Information(_Total)\\% Processor Time",
        "\\Memory\\Available MBytes",
        "\\LogicalDisk(_Total)\\Avg. Disk sec/Transfer"
      ]
    }
  }
}

