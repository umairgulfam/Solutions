variable "name_prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "storage_type" { type = string }
variable "share_quota_gb" { type = number }
variable "anf_subnet_id" { type = string }
variable "private_endpoint_subnet_id" { type = string }
variable "vnet_id" { type = string }
variable "enable_private_endpoint" { type = bool }
variable "private_only_data_plane" { type = bool }
variable "azure_files_directory_type" { type = string }
variable "azure_files_active_directory" {
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
variable "profile_principal_ids" { type = set(string) }
variable "anf_active_directory" {
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
variable "tags" { type = map(string) }
