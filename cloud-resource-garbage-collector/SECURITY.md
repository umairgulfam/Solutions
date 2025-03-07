# Security Policy

## Supported versions

Security fixes are applied to the latest release.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Use GitHub's private
security advisory feature. Include affected version, reproduction steps, and
impact. You should receive an acknowledgement within five business days.

## Operational safeguards

- Use workload identity, IAM roles, Azure managed identity, or GCP service
  accounts. Do not commit static credentials.
- Begin with read-only permissions and keep `CRGC_ENABLE_DELETION=false`.
- Restrict the API to a private network and rotate `CRGC_API_KEY`.
- Treat cost estimates as advisory and confirm dependencies before cleanup.
- Approval is mandatory, time-limited, recorded, and separate from execution.

