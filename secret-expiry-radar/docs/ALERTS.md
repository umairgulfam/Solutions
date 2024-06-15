# Notification setup

Use a disposable inventory and test-only notification destinations before production configuration. Notifications contain the name, owner, deadline, and days remaining; destination administrators can see that metadata.

## Environment variables

| Variable | Use |
|---|---|
| `SLACK_WEBHOOK_URL` | HTTPS Slack incoming webhook URL |
| `PAGERDUTY_ROUTING_KEY` | Events API v2 integration key |
| `SMTP_HOST` / `SMTP_PORT` | SMTP host and STARTTLS port; default 587 |
| `SMTP_FROM` / `SMTP_TO` | Sender and destination address |
| `SMTP_USER` / `SMTP_PASSWORD` | Optional SMTP credentials |
| `RADAR_API_TOKEN` | Dashboard bearer token; ≥32 characters for remote/container bind |
| `RADAR_DB` | SQLite path; native default `data/radar.db` |

SMTP always requires STARTTLS with certificate verification. Port 465 implicit TLS and OAuth SMTP authentication are not implemented. The `SMTP_TO` header can contain a comma-separated recipient list accepted by Python's email parser.

Slack and PagerDuty use HTTPS with certificate verification and no redirects. HTTP errors or transport exceptions do not mark a delivery successful. Error reports intentionally omit upstream response bodies and URLs to reduce accidental credential exposure.

```bash
python -m radar check
python -m radar check --send
```

A dry run records a run summary but never sends or consumes a delivery. Missing channel configuration appears as `not_configured`. A failed channel appears as `failed`. Both are retried on the next run without retrying successful channels. There is no rapid in-process retry loop; the default hourly worker retries at its next interval.

The 30-day channel is an application-local delivery ledger, not a browser push notification or external notification service. Dashboard counts include historical deadlines for existing assets. Run history retains the latest 100 runs, and the API exposes the latest 10. Delivery records persist until the asset is removed or the database is reset.

Overdue items remain eligible until delivery succeeds. Successful alerts are not repeated daily. PagerDuty receives a stable `dedup_key` derived from asset ID and deadline. A changed deadline creates a new key. Resolve old incidents through your incident workflow.

[PagerDuty Events API v2](https://developer.pagerduty.com/api-reference/f80f5db9acbe3-pager-duty-v2-events-api)
