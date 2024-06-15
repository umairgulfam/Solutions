# Operations runbook

## Deployment model

One host, one SQLite volume, one read-only dashboard, and one delivery worker. Use Docker Compose for the reference deployment. Do not scale the worker horizontally: delivery deduplication does not implement a distributed claim/lease. Schedule collectors independently and monitor their exit statuses.

The Docker image contains Python and this application only; install cloud CLIs on a separate trusted collection host. Export the host inventory to a temporary metadata file and import it into the container:

```bash
python -m radar export > inventory-export.json
docker compose cp inventory-export.json dashboard:/tmp/inventory-export.json
docker compose exec dashboard python -m radar import /tmp/inventory-export.json
docker compose exec dashboard rm /tmp/inventory-export.json
```

Protect and remove the host export when no longer needed. `/tmp` is a temporary filesystem in Compose. Never commit exports to the public repository.

## Health and monitoring

- `GET /healthz`: process liveness only; it does not validate database access, provider collection, or successful notifications.
- `GET /api/assets`: authenticated metadata and recent run summaries; no write API.
- Dashboard “latest monitoring run”: verify fresh timestamps and investigate skipped/failed channels.
- Worker logs: JSON summaries, no secret values; centrally collect and alert on failures or absent runs.
- Observe collector schedules independently: no persisted per-provider freshness telemetry exists in this version.
- A 60-second UI refresh does not imply a new cloud scan.

## Backup and restore

For a native installation, create a consistent SQLite snapshot using its backup API:

```bash
python -c "import sqlite3; s=sqlite3.connect('data/radar.db'); d=sqlite3.connect('radar-backup.db'); s.backup(d); d.close(); s.close()"
```

For Compose:

```bash
docker compose exec dashboard python -c "import sqlite3; s=sqlite3.connect('/data/radar.db'); d=sqlite3.connect('/tmp/radar-backup.db'); s.backup(d); d.close(); s.close()"
docker compose cp dashboard:/tmp/radar-backup.db ./radar-backup.db
```

Encrypt backups at rest and restrict permissions; metadata reveals system names, owners, account IDs, and deadlines. To restore, stop both services, replace the database using an administrative volume-maintenance container, preserve UID/GID 10001 ownership, then restart. Keep a pre-restore snapshot. A restored older delivery ledger may cause repeat notifications.

## Retire a credential

Verify it is revoked or decommissioned, then run:

```bash
python -m radar remove ASSET-ID
```

In Compose, prefix with `docker compose exec dashboard`. Retiring removes that record and its delivery ledger; save a backup if records must be retained. Future imports with the same ID can recreate it.

## Troubleshooting

| Symptom | Check |
|---|---|
| Container immediately exits | Set a generated token ≥32 characters in `.env` |
| Dashboard returns 401 | Enter the configured token; reload clears browser token memory |
| Database permission error | Data directory must be writable by UID 10001 in Docker |
| Skipped alert | Required channel variables are empty |
| SMTP delivery fails | STARTTLS support, port, sender policy, authentication |
| TLS collector fails | DNS, routing, SNI, trust chain, hostname match, certificate expiry |
| Dates remain unchanged | Collectors must run independently; worker only checks stored metadata |
| Duplicate alert after restart | Possible crash between remote acceptance and local persistence |
| Old AWS/Azure records remain | Imports do not reconcile deleted keys; retire explicitly |

## Remote use

Keep the provided published port on loopback. For remote teams, place a hardened HTTPS reverse proxy with organizational SSO in front, restrict inbound networks, run a production WSGI/ASGI-equivalent service adaptation after review, and provision backups/logging. The included standard-library HTTP server has no enterprise rate limiting or multiuser authorization. Do not directly expose it to the public internet.

## Updates

Review Dependabot changes and CI results. Rebuild images regularly for OS/Python updates; production release processes should pin reviewed image digests. Back up data before upgrades. This version initializes its schema with `CREATE TABLE IF NOT EXISTS`; future schema changes need an explicit migration strategy. Preserve the previous image and snapshot for rollback.
