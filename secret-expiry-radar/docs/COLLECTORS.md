# Collector setup and coverage

## TLS

```bash
python -m radar collect tls YOUR-HOSTNAME --owner "Platform team" --port 443
```

Uses a validated TLS handshake, hostname verification, SNI, system CA trust, and a 10-second socket timeout. A failed handshake leaves existing inventory untouched and exits nonzero. Expired, self-signed, or otherwise untrusted certificates are **not** bypassed: investigate the collection failure or import known metadata manually. This checks the leaf certificate of the endpoint reached, not every edge of a CDN or every certificate in the chain.

There is no dashboard endpoint for arbitrary URL fetching. CLI targets must be systems you are authorized to monitor. Schedule the command on a trusted management host and alert on its nonzero exit status; retained data can otherwise become stale.

## AWS IAM access keys

Install AWS CLI v2 and authenticate using your normal least-privilege profile or role:

```bash
aws sts get-caller-identity
python -m radar collect aws YOUR-IAM-USER --owner "Cloud operations" --rotation-days 90
```

The authenticated principal needs `iam:ListAccessKeys` for the specified IAM user and the ability to call STS `GetCallerIdentity`. The CLI handles list pagination. Only active keys are imported. The ID includes the AWS account and access-key ID; metadata can still be sensitive. Secret access-key values are never requested. This is a single-user collector, not organization-wide discovery, and it does not read key last-used data.

Example IAM permission statement (replace the ARN):

```json
{"Effect":"Allow","Action":"iam:ListAccessKeys","Resource":"arn:aws:iam::123456789012:user/YOUR-IAM-USER"}
```

Inactive/deleted keys are not automatically removed from the existing inventory. Review and retire them explicitly. AWS IAM access keys have no intrinsic expiration; rotation dates are your policy.

## Azure application credentials

Install Azure CLI and sign in to the correct tenant:

```bash
az login --tenant YOUR-TENANT-ID
python -m radar collect azure YOUR-APPLICATION-ID --owner "Identity team"
```

Uses `az account show` for tenant identity and `az ad app credential list` for metadata. The calling identity needs permission to read the target application credentials. An application owner may have sufficient delegated access; centrally managed discovery may require Microsoft Graph application-read permissions and administrator consent. Ask your tenant administrator for the narrowest appropriate access rather than granting broad write permissions.

The collector covers application-registration credentials returned by this CLI. It does not enumerate all service principals or Key Vaults. If a service principal has independently managed credentials, export those separately. Only allowlisted fields are imported; credential hints and secret text are discarded.

## Other credential types

| Type | Supported path | Limitation |
|---|---|---|
| API keys | JSON metadata import | Expiry depends on issuer |
| GitHub tokens | JSON metadata import | No general token-discovery collector |
| SSH keys | JSON import + rotation policy | Ordinary public/private keys do not encode expiry |
| DNS-service certificates | JSON import; TLS collector for a reachable TLS endpoint | No DNSSEC/ACME/domain-renewal implementation |
| OAuth credentials | JSON metadata import | Token lifetime and client-secret lifetime are different |
| Azure Key Vault secrets | JSON metadata import | No native Key Vault connector |

## Collection scheduling

The alert worker evaluates the database; it does not call cloud providers. Schedule collection before alerting using cron, your CI scheduler, or your cloud job service. A sample host crontab is in `examples/crontab.example`. Use an explicit working directory and database path. Never run two delivery workers against the same database.

## Primary references

- [AWS security credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/security-creds.html)
- [Managing IAM access keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html)
- [Microsoft Graph passwordCredential and endDateTime](https://learn.microsoft.com/en-us/graph/api/resources/passwordcredential?view=graph-rest-1.0)
- [Azure CLI application credential commands](https://learn.microsoft.com/en-us/cli/azure/ad/app/credential)
