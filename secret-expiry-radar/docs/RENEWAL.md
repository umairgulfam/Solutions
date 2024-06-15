# Optional renewal design

Automatic renewal was an optional extension in the scenario and is **not enabled or implemented in v1.0**. This repository never changes provider credentials.

For an ACME-managed TLS certificate, a provider-supported renewal agent such as Certbot can renew the certificate outside Radar. Radar should then rescan the endpoint and confirm the deployed certificate changed. Renewing a file is not proof the service is presenting the new certificate.

For API keys and application credentials, a safe rotation workflow needs:

1. An explicit allowlist of resource IDs and a narrowly scoped workload identity.
2. Creation of a replacement credential in the provider.
3. Storage in an approved vault, with no value entering Radar or logs.
4. A controlled rollout to every dependent workload.
5. Health checks and an overlap period where supported.
6. Revocation of the old credential only after successful verification.
7. Metadata refresh, audit evidence, and rollback handling.

Do not add a dashboard “renew” button backed by arbitrary shell commands. Implement provider-specific adapters, approval policies where required, and integration tests in a non-production account first. Most ordinary SSH key rotation and long-term AWS access-key rotation are replacement workflows, not extensions of an expiry date.
