# Cloud Resource Garbage Collector

[![CI](https://github.com/YOUR_GITHUB_USERNAME/cloud-resource-garbage-collector/actions/workflows/ci.yml/badge.svg)](https://github.com/YOUR_GITHUB_USERNAME/cloud-resource-garbage-collector/actions/workflows/ci.yml)
[![CodeQL](https://github.com/YOUR_GITHUB_USERNAME/cloud-resource-garbage-collector/actions/workflows/codeql.yml/badge.svg)](https://github.com/YOUR_GITHUB_USERNAME/cloud-resource-garbage-collector/actions/workflows/codeql.yml)
[![Python 3.11+](https://img.shields.io/badge/python-3.11%2B-3776AB.svg)](https://www.python.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An approval-gated FinOps and cloud-governance tool that inventories AWS, Azure,
and GCP resources, identifies likely waste, explains the evidence, estimates
monthly savings, resolves ownership from tags, and records every decision.

> Safety first: all real-cloud adapters are read-only. Deletion is disabled by
> default and only the deterministic mock provider implements deletion for the
> end-to-end demo.

## What it detects

| Resource | Suspicion signal |
| --- | --- |
| Virtual machine | Sustained CPU below 2% and no network activity |
| Public IP | No resource association |
| Managed disk | No VM attachment |
| Snapshot | Older than the retention threshold |
| Network interface | No parent VM/resource |
| Load balancer | No registered backends |
| Database | Stopped or zero connections |
| NAT gateway | No observed traffic |
| Container image | Untagged or older than retention |

Every finding has this decision path:

`Resource → evidence → estimated monthly cost → owner → approve / reject / ignore → separately gated deletion`

## Portfolio highlights

- Multi-cloud adapter architecture with a normalized Pydantic model
- Deterministic policy engine and idempotent SHA-256 finding fingerprints
- Approval state machine, audit log, and explicit separation of duties
- FastAPI REST API and responsive operational dashboard
- Typer CLI with table, JSON, and CSV reporting
- SQLite locally, with a SQLAlchemy boundary ready for PostgreSQL
- Docker, Compose, tests, coverage gate, linting, Bandit, CodeQL, and Dependabot
- Least-privilege guidance and a production operations runbook

## Quick start: safe demo

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/cloud-resource-garbage-collector.git
cd cloud-resource-garbage-collector
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate
python -m pip install -e ".[all,dev]"
cp .env.example .env       # Windows: copy .env.example .env
crgc scan --provider mock
```

The demo includes the requested 10-month-old VM scenario: 0.2% CPU, no network
traffic, and an estimated cost of $86/month.

### Dashboard

Set a strong `CRGC_API_KEY` in `.env`, then:

```bash
crgc seed-demo
uvicorn garbage_collector.api:app --reload --port 8080
```

Open `http://localhost:8080`, enter the API key, and review findings. Interactive
API documentation is available at `http://localhost:8080/docs`.

### Docker

```bash
cp .env.example .env
docker compose up --build
```

## Scan a cloud

Install the relevant optional dependency, authenticate using the provider's
recommended workload identity, and follow [least-privilege permissions](docs/PERMISSIONS.md).

```bash
crgc scan --provider aws
crgc scan --provider azure
crgc scan --provider gcp
crgc scan --provider aws --provider azure --provider gcp --output json --file reports/findings.json
```

Provider inventory coverage in v1 focuses on reliably identifiable detached or
aged resources. The policy model covers all nine categories; extend collectors
with metrics and billing APIs for production-grade utilization and exact cost.

## Approval workflow

```bash
# 1. Scan and copy a finding fingerprint
crgc scan --provider mock

# 2. Owner/reviewer decision
crgc decide FINGERPRINT approved reviewer@example.com --comment "Change CHG-1042"

# 3. Demo execution only: explicitly enable and confirm
export CRGC_ENABLE_DELETION=true
crgc delete FINGERPRINT operator@example.com --confirm
```

Valid transitions are:

- `pending → approved → deleted` or `failed`
- `pending → rejected`
- `pending → ignored`
- `approved → rejected`

## API examples

```bash
curl -X POST http://localhost:8080/api/v1/scans \
  -H "X-API-Key: $CRGC_API_KEY" -H "Content-Type: application/json" \
  -d '{"providers":["mock"]}'

curl http://localhost:8080/api/v1/findings \
  -H "X-API-Key: $CRGC_API_KEY"
```

See [architecture](docs/ARCHITECTURE.md), [runbook](docs/RUNBOOK.md), and
[security policy](SECURITY.md) before adapting this project to production.

## Test and quality gates

```bash
make lint
make test
make security
docker build -t cloud-resource-garbage-collector .
```

GitHub Actions runs the same checks on every pull request and builds the image.

## Repository structure

```text
.
├── .github/                 # CI, CodeQL, Dependabot, templates
├── config/policies.yaml     # Policy reference and thresholds
├── docs/                    # Architecture, permissions, runbook
├── src/garbage_collector/   # API, CLI, policies, workflow, providers
├── tests/                   # Detector, API, and approval tests
├── Dockerfile
├── docker-compose.yml
├── Makefile
└── pyproject.toml
```

## Roadmap

- Cloud-native utilization and billing integrations for exact estimates
- PostgreSQL, SSO/RBAC, notifications, and asynchronous scan jobs
- Quarantine/tag-and-wait workflow before irreversible cleanup
- Organization policy packs, exceptions with expiry, and scheduled rescans
- Provider-specific dependency graphs and narrowly scoped cleanup executors

## Disclaimer

This project produces cleanup candidates, not authoritative deletion decisions.
Validate business ownership, dependencies, backups, compliance retention, and
provider billing before any change.

## License

[MIT](LICENSE) © 2026 Umair Gulfam

