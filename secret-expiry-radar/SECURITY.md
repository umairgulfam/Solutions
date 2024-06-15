# Security policy

Report suspected vulnerabilities privately to the repository owner using GitHub private vulnerability reporting when enabled. Do not post credential values, real inventory exports, tenant IDs, or webhook URLs in public issues. Until private reporting is configured, contact the maintainer through an independently verified private channel.

## Threat model

Radar protects against common accidental secret handling by accepting only metadata fields, using read-only HTTP endpoints, keeping network collection in an operator CLI, validating outbound TLS, avoiding webhook redirects, and excluding runtime data from Git/Docker build context. Bearer comparison is timing-safe. UI metadata is inserted through `textContent` rather than HTML injection. A restrictive CSP blocks external scripts and framing.

It does not protect against a compromised host/operator, secrets pasted into legitimate name fields, malicious authorized inventory editors, resource exhaustion of the development HTTP server, or a leaked dashboard token. Metadata itself can be sensitive. SQLite is not encrypted by this application. Use operating-system permissions and encrypted storage.

Cloud CLI identities should have read permissions only. Notification credentials are environment-provided. Do not use production root/cloud-administrator credentials, commit tokens, store private keys in the inventory, or publish runtime database files. Never expose the built-in HTTP server directly to the internet.

This project is a reference implementation and has not undergone an independent security audit. Refer to the documented limits before adopting it for production.
