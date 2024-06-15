# Inventory reference

An import file is a JSON array of objects. All timestamps must include a timezone; UTC `Z` is recommended.

| Field | Required | Meaning |
|---|---|---|
| `id` | Yes | Stable unique ID, 1–200 characters |
| `name` | Yes | Human-readable name, 1–200 characters |
| `kind` | Yes | One of the kinds below |
| `owner` | Yes | Team or responsible person, 1–200 characters |
| `environment` | Yes | Such as `production`, `staging`, `demo` |
| `expires_at` | No | Actual provider-issued expiration timestamp |
| `created_at` | For rotation | Creation or last-rotation timestamp |
| `rotation_days` | No | Integer 1–3650; requires `created_at` |
| `source` | No | Collector identifier, maximum 300 characters |

Kinds: `tls`, `api_key`, `aws_access_key`, `azure_secret`, `github_token`, `ssh_key`, `dns_certificate`, `oauth_credential`.

Unrecognized fields are rejected. Do not put secrets, passwords, tokens, private keys, webhook URLs, or connection strings in any string field. Field allowlisting cannot detect every secret pasted into a legitimate metadata field.

The earlier of expiration and rotation deadlines is used. Time remaining is rounded up for display, while urgency uses exact elapsed seconds. At the exact deadline the status becomes overdue. Records with missing deadlines remain unknown.

Imports validate the entire batch before writing, reject duplicate IDs within a batch, and upsert matching IDs transactionally. They never remove other assets. Use a stable ID for a logical credential, or a provider key ID where available. A changed deadline becomes eligible for a new delivery sequence.

To retire a revoked asset, use `python -m radar remove ASSET-ID` after verifying revocation. The operation removes that asset and its delivery history. Back up the database first if history must be retained.
