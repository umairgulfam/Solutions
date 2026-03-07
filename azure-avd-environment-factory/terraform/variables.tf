variable "subscription_id" {
  description = "Azure subscription ID."
  type        = string
}

variable "tenant_id" {
  description = "Microsoft Entra tenant ID."
  type        = string
}

variable "location" {
  description = "Primary Azure region."
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Environment identifier used in names and tags."
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be dev, test, or prod."
  }
}

variable "name_prefix" {
  description = "Short lowercase organization or workload prefix."
  type        = string
  default     = "avdf"
  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.name_prefix))
    error_message = "name_prefix must contain 2-8 lowercase letters or numbers."
  }
}

variable "capacity_profile" {
  description = "Built-in sizing profile: small, medium, large, or custom."
  type        = string
  default     = "custom"
  validation {
    condition     = contains(["small", "medium", "large", "custom"], var.capacity_profile)
    error_message = "capacity_profile must be small, medium, large, or custom."
  }
}

variable "host_pools" {
  description = "Custom host pools. Used when capacity_profile is custom."
  type = map(object({
    type                     = optional(string, "Pooled")
    load_balancer_type       = optional(string, "BreadthFirst")
    personal_assignment_type = optional(string, "Automatic")
    session_hosts            = number
    vm_size                  = string
    max_sessions             = optional(number, 16)
    image_id                 = optional(string)
    image_publisher          = optional(string, "MicrosoftWindowsDesktop")
    image_offer              = optional(string, "windows-11")
    image_sku                = optional(string, "win11-23h2-avd")
    image_version            = optional(string, "latest")
    zone                     = optional(string)
    scaling_enabled          = optional(bool, true)
    scaling_timezone         = optional(string, "UTC")
    peak_start_time          = optional(string, "07:00")
    peak_end_time            = optional(string, "19:00")
    peak_minimum_hosts_pct   = optional(number, 20)
    off_peak_minimum_hosts   = optional(number, 0)
    shutdown_enabled         = optional(bool, false)
    shutdown_time            = optional(string, "22:00")
    tags                     = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for pool in values(var.host_pools) :
      contains(["Pooled", "Personal"], pool.type) && pool.session_hosts >= 0
    ])
    error_message = "Each host pool type must be Pooled or Personal and session_hosts cannot be negative."
  }
}

variable "join_type" {
  description = "Session-host identity join: entra or active_directory."
  type        = string
  default     = "entra"
  validation {
    condition     = contains(["entra", "active_directory"], var.join_type)
    error_message = "join_type must be entra or active_directory."
  }
}

variable "domain_name" {
  description = "AD DS domain FQDN; required for active_directory join."
  type        = string
  default     = ""
}

variable "domain_ou_path" {
  description = "Optional AD DS OU distinguished name."
  type        = string
  default     = ""
}

variable "domain_join_username" {
  description = "AD DS domain join user UPN; required for active_directory join."
  type        = string
  default     = ""
}

variable "domain_join_password" {
  description = "AD DS domain join password. Pass through a secret environment variable."
  type        = string
  sensitive   = true
  default     = ""
}

variable "admin_username" {
  description = "Local session-host administrator name."
  type        = string
  default     = "avdadmin"
}

variable "admin_password" {
  description = "Optional local password. A random password is generated when null."
  type        = string
  sensitive   = true
  default     = null
  nullable    = true
}

variable "vnet_address_space" {
  type    = list(string)
  default = ["10.40.0.0/16"]
}

variable "session_host_subnet_prefixes" {
  type    = list(string)
  default = ["10.40.10.0/24"]
}

variable "private_endpoint_subnet_prefixes" {
  type    = list(string)
  default = ["10.40.20.0/24"]
}

variable "anf_subnet_prefixes" {
  description = "Dedicated delegated subnet for Azure NetApp Files."
  type        = list(string)
  default     = ["10.40.30.0/24"]
}

variable "dns_servers" {
  description = "Custom DNS servers, normally required for AD DS join."
  type        = list(string)
  default     = []
}

variable "fslogix_storage_type" {
  description = "azure_files or anf."
  type        = string
  default     = "azure_files"
  validation {
    condition     = contains(["azure_files", "anf"], var.fslogix_storage_type)
    error_message = "fslogix_storage_type must be azure_files or anf."
  }
}

variable "fslogix_share_quota_gb" {
  type    = number
  default = 1024
}

variable "azure_files_directory_type" {
  description = "Azure Files identity source: AADKERB for Entra Kerberos or AD for AD DS."
  type        = string
  default     = "AADKERB"
  validation {
    condition     = contains(["AADKERB", "AD"], var.azure_files_directory_type)
    error_message = "azure_files_directory_type must be AADKERB or AD."
  }
}

variable "azure_files_active_directory" {
  description = "AD DS properties required when Azure Files directory_type is AD."
  type = object({
    domain_name         = string
    domain_guid         = string
    domain_sid          = string
    storage_sid         = string
    forest_name         = string
    netbios_domain_name = string
  })
  default  = null
  nullable = true
}

variable "anf_active_directory" {
  description = "Active Directory configuration required for ANF SMB profiles."
  type = object({
    dns_servers         = list(string)
    domain              = string
    smb_server_name     = string
    username            = string
    password            = string
    organizational_unit = optional(string)
  })
  sensitive = true
  default   = null
  nullable  = true
}

variable "enable_private_endpoints" {
  type    = bool
  default = false
}

variable "private_only_data_plane" {
  description = "Disable public access after private endpoints exist. Requires a self-hosted runner with VNet and DNS access."
  type        = bool
  default     = false
}

variable "rbac" {
  description = "Principal IDs for AVD user and administrator roles."
  type = object({
    desktop_user_principal_ids = optional(set(string), [])
    admin_principal_ids        = optional(set(string), [])
  })
  default = {}
}

variable "monthly_budget_amount" {
  description = "Monthly budget in billing currency; zero disables it."
  type        = number
  default     = 0
}

variable "budget_contact_emails" {
  type    = list(string)
  default = []
}

variable "tags" {
  type = map(string)
  default = {
    managed-by = "terraform"
    workload   = "azure-virtual-desktop"
  }
}
