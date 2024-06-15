# Validation report

The following checks were actually run during package preparation using Python 3.12.13:

| Check | Result |
|---|---|
| `python -m unittest discover -s tests -v` | 17 tests passed |
| `python -m compileall -q radar` | Passed |
| `node --check radar/static/app.js` | Passed |
| CLI demo → dry-run check → export → remove → export | Passed against a temporary database |
| Example demo inventory | 8 synthetic assets; 16 eligible cumulative channel deliveries |
| YAML parsing for Compose, CI and Dependabot | Passed |
| Offline Python wheel build | Passed; package built without runtime dependencies |
| HTTP tests | Real local HTTP requests verified authentication, static routes, health and security headers |

## Not executed here

- Docker build/run: Docker is not installed in the preparation workspace. CI contains a container build and HTTP smoke test.
- GitHub-hosted CI: not yet triggered; requires pushing the repository.
- Live AWS, Azure, TLS endpoint collection and external Slack/SMTP/PagerDuty delivery: no user credentials or destinations were configured. Collector mapping and PagerDuty payload behavior were tested with mocks.
- Browser rendering/accessibility/device testing: not performed. UI assets received syntax/route checks only.
- Production deployment, independent security audit, load testing, or automatic renewal: not performed.

Run the supplied validation commands and CI in your environment, then test integrations against disposable credentials and test-only notification destinations before operational use. Passing unit tests does not demonstrate live provider connectivity.
