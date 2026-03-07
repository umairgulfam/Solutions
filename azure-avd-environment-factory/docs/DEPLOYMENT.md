# Deployment Guide

## Prerequisites

- Terraform 1.7 or newer
- Azure CLI and PowerShell 7 with Az.DesktopVirtualization
- An Azure subscription with AVD and NetApp providers registered as needed
- Permission to create networking, compute, AVD, monitoring, Key Vault, role
  assignments, and budgets
- Remote state storage for shared or production use

## Local plan

```bash
az login
az account set --subscription SUBSCRIPTION_ID
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
terraform -chdir=terraform plan
```

Never commit the populated `.tfvars`, state, or plan file.

For Azure NetApp Files SMB, provide `anf_active_directory` through a protected
variable source. The framework creates a dedicated delegated ANF subnet; verify
DNS reachability to the domain controllers before deployment.

## GitHub Actions OIDC

Create a Microsoft Entra application or user-assigned managed identity with a
federated credential for this repository. Configure these repository or
organization secrets so both the plan and apply jobs can authenticate:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

Create protected `dev`, `test`, and `production` GitHub environments. Require a
reviewer for production; the environment gate pauses the apply job after the
plan artifact is produced. Copy `backend.tf.example` to `backend.tf`, configure
the remote state values, and keep each environment on a distinct state key.

The manual deployment workflow creates a binary plan, uploads it with one-day
retention, pauses at the protected environment, and applies that exact artifact.
Plan artifacts can contain sensitive values, so repository access and Actions
artifact access must be tightly controlled.

## Private-only deployment

`enable_private_endpoints=true` adds private connectivity without immediately
disabling the public data plane. Setting `private_only_data_plane=true` also
disables public access to Key Vault and Azure Files. That mode requires a
self-hosted GitHub runner with VNet routing and private DNS resolution; the
included GitHub-hosted runner is intended for the default public deployment
control plane.

## Azure Files identity

Use `AADKERB` for Microsoft Entra Kerberos or `AD` with the complete
`azure_files_active_directory` object. Configured desktop-user principals are
assigned **Storage File Data SMB Share Contributor** on the profile storage
account. Validate Kerberos prerequisites and NTFS-level permissions separately.
