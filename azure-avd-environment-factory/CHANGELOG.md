# Changelog

## [1.1.0] - 2026-09-05

### Changed

- Made session-host computer names deterministic and collision resistant.
- Added Azure Files Entra Kerberos or AD DS authentication configuration.
- Added FSLogix share RBAC for configured desktop-user principals.
- Separated private endpoints from private-only data-plane enforcement.
- Changed the apply pipeline to consume the exact reviewed plan artifact.
- Added native Terraform capacity-profile tests and input safety checks.

## [1.0.0] - 2026-09-05

### Added

- Map-driven AVD host pools and session hosts.
- Small, medium, large, and custom capacity profiles.
- Pooled and personal desktop support.
- Per-pool scaling schedules, workspaces, and application groups.
- Azure Files or Azure NetApp Files FSLogix storage.
- Entra ID or Active Directory join options.
- Network, NSG, monitoring, Key Vault, RBAC, budgets, shutdown schedules,
  private endpoints, validation scripts, and GitHub Actions.
