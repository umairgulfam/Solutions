variable "name_prefix" { type = string }
variable "pool_key" { type = string }
variable "host_pool_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "session_host_count" { type = number }
variable "vm_size" { type = string }
variable "zone" {
  type     = string
  default  = null
  nullable = true
}
variable "subnet_id" { type = string }
variable "host_pool_registration_token" {
  type      = string
  sensitive = true
}
variable "admin_username" { type = string }
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "join_type" { type = string }
variable "tenant_id" { type = string }
variable "domain_name" { type = string }
variable "domain_ou_path" { type = string }
variable "domain_join_username" { type = string }
variable "domain_join_password" {
  type      = string
  sensitive = true
}
variable "image_id" {
  type     = string
  default  = null
  nullable = true
}
variable "image_publisher" { type = string }
variable "image_offer" { type = string }
variable "image_sku" { type = string }
variable "image_version" { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "data_collection_rule_id" { type = string }
variable "shutdown_enabled" { type = bool }
variable "shutdown_time" { type = string }
variable "shutdown_timezone" { type = string }
variable "tags" { type = map(string) }
