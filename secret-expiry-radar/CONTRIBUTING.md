# Contributing

Use Python 3.11 or newer. No third-party runtime dependency is needed.

```bash
python -m unittest discover -s tests -v
python -m compileall -q radar
node --check radar/static/app.js
```

Keep credential values out of fixtures. Use synthetic inventory and mock external calls in tests. For a collector, document its scope, permissions, pagination, missing-expiry behavior, failure behavior, and deletion/reconciliation behavior. For a notifier, test successful delivery, missing configuration, retry, and deduplication.

Do not grant cloud write permissions for monitoring. Provider-specific renewal proposals need a separate design and rollback plan. Document operational limitations and configuration changes in pull requests. Run Docker CI before treating an image change as ready for deployment.
