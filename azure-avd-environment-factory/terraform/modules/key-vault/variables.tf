variable "name_prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tenant_id" { type = string }
variable "current_principal_id" { type = string }
variable "admin_username" { type = string }
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "enable_private_endpoint" { type = bool }
variable "private_only_data_plane" { type = bool }
variable "private_endpoint_subnet_id" { type = string }
variable "vnet_id" { type = string }
variable "tags" { type = map(string) }
