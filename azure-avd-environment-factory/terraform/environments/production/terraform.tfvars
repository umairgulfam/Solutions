environment      = "prod"
name_prefix      = "demo"
capacity_profile = "large"

fslogix_storage_type     = "azure_files"
enable_private_endpoints = true
private_only_data_plane  = false
monthly_budget_amount    = 6000
budget_contact_emails    = ["finops@example.com", "cloud-ops@example.com"]
