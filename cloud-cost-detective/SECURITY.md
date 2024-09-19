# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 0.3.x | yes |
| < 0.3 | no |

## Reporting a vulnerability

Please do **not** open a public issue.

Use GitHub's private vulnerability reporting (Security → Report a vulnerability)
or email security@your-org.example. Include the version, a reproduction, and the
impact as you see it. Expect an acknowledgement within three working days.

## Security posture of this tool

Worth understanding before you deploy it:

- **It only reads.** No code path tags, resizes, terminates or otherwise modifies
  a cloud resource. The Terraform module in `deploy/terraform` grants read-only
  Cost Explorer and tag-describe permissions and nothing else.
- **It holds no credentials.** Auth is delegated to the provider SDKs — the AWS
  default credential chain and Azure `DefaultAzureCredential`. Nothing is
  persisted to disk.
- **It stores no history.** There is no database and no state file. Each run is
  independent, so there is no accumulated cost dataset to breach.
- **Config expands env vars** (`${VAR}`) so secrets stay out of committed YAML.
  `costdetective.yaml` is gitignored by default for this reason.

## Handling of output

Reports contain account identifiers, resource addresses, internal service names,
team names and commit authors. Treat them as internal data:

- Slack webhooks should point at a private channel.
- CI artefacts containing reports have a retention limit set; keep it short.
- Redact before attaching output to a public issue.

## Dependencies

The runtime dependency surface is deliberately one package (PyYAML). Cloud SDKs
are optional extras, so a deployment only installs the provider it uses.
Dependabot monitors both the Python and GitHub Actions ecosystems.
