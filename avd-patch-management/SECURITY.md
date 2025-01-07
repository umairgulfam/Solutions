# Security Policy

## Reporting

Do not open a public issue. Use GitHub's private vulnerability reporting or
email security@your-org.example. Expect acknowledgement within three working
days.

## Threat model

This tool installs code as SYSTEM on every session host in a pool. That makes
the supply chain from catalog to host the thing worth protecting.

| Threat | Control |
| --- | --- |
| Tampered package in storage | SHA256 recorded at download, verified before DISM. A mismatch aborts and deletes the file. |
| Compromised session host poisons the fleet | Hosts hold Storage Blob Data **Reader** only. They cannot write packages or manifests. |
| Stolen storage credential | Shared key access disabled; managed identity only. No SAS in config by default. |
| Local privilege escalation via the install path | Install directory ACL is SYSTEM/Administrators full, Users read-execute. |
| Man-in-the-middle on download | HTTPS throughout, plus the hash check, which is what actually catches a substituted payload. |
| Malicious manifest | Written only by the automation identity. Treat write access to that container as equivalent to SYSTEM on every host. |

## What this does not protect against

- **A genuinely malicious Microsoft update.** The hash proves the file is what
  the catalog served, not that the update is safe. That is what canary pools and
  phased rollout are for — and this tool deliberately bypasses phased rollout.
- **Compromise of the automation identity.** Anyone who can write to the patch
  container can execute code as SYSTEM fleet-wide. Protect that identity
  accordingly: no shared credentials, audit role assignments, alert on changes.
- **A compromised golden image.** Out of scope.

## Operational guidance

- Restrict the storage account with a private endpoint or service endpoint
  limited to the AVD subnets. The template ships with `defaultAction: Allow` so
  it deploys unmodified; tighten it in production.
- Audit role assignments on the patch container as a change-controlled item.
- Alert on script 1 failing. A silent failure means an unpatched month, which is
  the failure most likely to go unnoticed.
- Logs and reports contain host names, storage account names and build numbers.
  Treat them as internal.
