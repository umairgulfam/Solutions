# Security Policy

Report vulnerabilities through GitHub private security advisories rather than
public issues.

## Deployment safeguards

- Authenticate GitHub Actions with Azure workload identity federation (OIDC).
- Store no passwords, client secrets, state files, or live `.tfvars` in Git.
- Use a private Terraform state backend with blob versioning and soft delete.
- Require pull-request review and an environment approval for production apply.
- Restrict session-host egress and use private endpoints where required.
- Review plan output for destructive changes, especially when removing a map key.

