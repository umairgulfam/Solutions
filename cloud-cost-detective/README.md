# Cloud Cost Detective

> Your bill went up $47 yesterday. Every cloud console will tell you that. None of them tell you **who did it, why, or what to do about it.**

Cloud Cost Detective correlates a cost increase against the things that actually changed in your estate and produces a verdict an on-call engineer can act on without opening six browser tabs.

```
cost increase  +  Terraform changes  +  cloud resources  +  git commits  =  likely cause
```

[![CI](https://github.com/your-org/cloud-cost-detective/actions/workflows/ci.yml/badge.svg)](https://github.com/your-org/cloud-cost-detective/actions/workflows/ci.yml)
[![Python 3.10+](https://img.shields.io/badge/python-3.10%2B-blue.svg)](https://www.python.org/downloads/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

---

## What it looks like

```console
$ costdetective report --demo

Today's increase: +$47

Reason:
RDS             +$18
AI Foundry      +$13
EC2             +$12
API Gateway     +$4

Likely cause:
AI Foundry resource created yesterday.

Owner:
AI-R&D

Suggested action:
Review unused deployment.
```

Ask for the reasoning behind any single line:

```console
$ costdetective explain "AI Foundry" --demo

AI Foundry: +$13 (+325.0%)
  $4 -> $17
  owner: AI-R&D  [tag:Team]
  suggested action: Review unused deployment.

  suspects:
   1. [terraform] azurerm_cognitive_deployment.gpt4o_rnd — AI Foundry resource created yesterday (98% high)
      when: 2026-09-01 22:00  author: s.raza
      - touches azurerm_cognitive_deployment, which bills to AI Foundry
      - change text references AI Foundry
      - landed 26h before the cost movement
      - creates new billable capacity
   2. [git] 9f3ac21 — feat(ai): add gpt-4o deployment for evaluation harness (48% medium)
      ...
```

Every number comes with the evidence behind it. You should be able to disagree with the tool, not just trust it.

---

## Why this exists

Native cost tooling answers *"what did we spend?"*. The question that actually costs an engineering team time is *"what did we change?"* — and that answer lives in Terraform state, git history and resource tags, not in the billing console.

This tool joins those together. It is deliberately small: one Python package, one runtime dependency (PyYAML), no database, no agent, no vendor account. It runs in CI, in a cron job, or on a laptop.

**What it is not:** a replacement for Cost Explorer, CloudHealth or Vantage. It does not forecast, it does not do RI/savings-plan optimisation, and it does not store history. It answers one question well.

---

## Quickstart

```bash
git clone https://github.com/your-org/cloud-cost-detective.git
cd cloud-cost-detective
pip install -e ".[dev]"

costdetective report --demo          # no credentials required
```

The `--demo` flag uses a bundled fixture, so you can see the full output — and run the entire test suite — without touching a cloud account.

### Against real AWS

```bash
pip install -e ".[aws]"

export AWS_PROFILE=finops
costdetective report --source aws --change-source terraform --change-source git
```

Needs one IAM permission: `ce:GetCostAndUsage`. A ready-made least-privilege role is in [`deploy/terraform/`](deploy/terraform/).

### Against real Azure

```bash
pip install -e ".[azure]"

export COSTDETECTIVE_AZURE_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000
costdetective report --source azure
```

Authentication goes through `DefaultAzureCredential`, so managed identity, workload identity, a service principal or plain `az login` all work without code changes.

---

## Configuration

Drop a `costdetective.yaml` next to your repo — see [`costdetective.example.yaml`](costdetective.example.yaml) for the fully commented version:

```yaml
cost_source: aws
change_sources: [terraform, git]

correlation_window_hours: 72   # how far back a change can be blamed
min_delta: 1.00                # ignore movements smaller than this

terraform:
  plan_json: ./tfplan.json

git:
  repo: ./infra

ownership:
  tag_keys: [Owner, Team, CostCenter]
  by_service:
    "API Gateway": platform-team
  by_path:
    "ai-platform/": AI-R&D
  default: finops

thresholds:
  fail: 100.00                 # exit 2 above this, to gate a pipeline

notify:
  slack_webhook: ${SLACK_WEBHOOK_URL}
```

Values resolve in this order, last one wins: **built-in defaults → YAML file → `COSTDETECTIVE_*` env vars → CLI flags.** `${VAR}` and `${VAR:-fallback}` are expanded from the environment inside the YAML, so no secret needs to live in the file.

Check your config before you rely on it:

```bash
costdetective validate --check-access
```

That validates the schema *and* probes every configured source for credentials — the failure you want to catch in staging rather than at 3am.

---

## How the correlation works

For each service whose spend rose, every candidate change is scored on four independent signals:

| Signal | Weight | Meaning |
| --- | ---: | --- |
| Resource match | 0.50 | the change touches a resource type that bills to this service |
| Keyword match | 0.25 | the change text mentions the service |
| Recency | 0.20 | decays linearly across the correlation window |
| Creation bonus | 0.15 | new resources explain new spend better than edits do |

Two rules matter more than the weights:

**Timing alone is never evidence.** A change with no resource-type or keyword link to a service scores exactly zero, however recent it is. Without that rule, everything merged yesterday looks guilty — which is how cost tools train people to ignore them.

**The headline is not the biggest number.** Findings are ranked by `delta × confidence × anomaly`, where anomaly is relative change capped at 3×. A service going $4 → $17 (+325%) outranks a mature service drifting +12%, even though the drift is worth more dollars. The large delta is usually normal growth; the spike is usually the thing someone broke.

Full detail, including how to retune the weights, is in [`docs/scoring.md`](docs/scoring.md).

---

## Running it in CI

### Daily report to Slack

[`.github/workflows/daily-cost-report.yml`](.github/workflows/daily-cost-report.yml) runs every weekday morning, authenticates to AWS with OIDC (no static keys), and posts the verdict to Slack.

### Failing a PR on a cost spike

`--fail-over` turns the tool into a gate:

```yaml
- name: Cost gate
  run: costdetective report --source aws --fail-over 100 --format markdown -o report.md
```

Exit codes: `0` clean, `1` runtime error, `2` threshold breached. [`pr-cost-check.yml`](.github/workflows/pr-cost-check.yml) shows the full pattern — it runs `terraform plan`, correlates the *planned* changes, and comments the Markdown report on the PR.

### As a Kubernetes CronJob

```bash
kubectl apply -f deploy/kubernetes/cronjob.yaml
```

Runs as non-root with a read-only root filesystem and all capabilities dropped.

---

## Output formats

| Format | Flag | Use for |
| --- | --- | --- |
| Text | `-f text` | terminals, Slack code blocks |
| JSON | `-f json` | piping into jq, dashboards, alerting |
| Markdown | `-f markdown` | PR comments, wikis, email |
| Slack Block Kit | `--slack` | posting straight to a webhook |

```bash
# Which teams are driving today's increase?
costdetective report --demo -f json | jq -r '.findings[] | "\(.owner)\t\(.service.delta)"'
```

---

## Extending it

Adding a provider means implementing one abstract method and registering it. Nothing else in the codebase changes.

```python
from costdetective.sources.base import CostSource

class GcpCostSource(CostSource):
    name = "gcp"

    def fetch(self, days: int = 1) -> CostSnapshot:
        ...
```

Then add it to the registry in `sources/__init__.py`. Same shape for change sources — a CloudTrail or Kubernetes-events source slots in identically.

To teach it about resource types it doesn't know, extend the service map from your own config:

```yaml
service_map:
  resource_types:
    aws_kinesis_stream: Kinesis
  actions:
    Kinesis: "Check shard count — shards bill hourly whether used or not."
```

---

## Project layout

```
src/costdetective/
├── cli.py            # argparse entrypoint, exit codes
├── config.py         # layered config, env expansion, validation
├── models.py         # dataclasses shared by the whole pipeline
├── engine.py         # the correlation scoring
├── ownership.py      # tags → config → commit author fallback chain
├── report.py         # text / json / markdown / slack renderers
├── servicemap.py     # resource types → billable services
├── sources/          # aws, azure, terraform, git, demo
├── notify/           # slack webhook
└── data/             # service map + demo fixture
```

---

## Development

```bash
make install     # editable install with dev extras
make test        # pytest with coverage
make lint        # ruff + mypy
make demo        # run the offline scenario
make docker      # build the image
```

The suite runs fully offline. `make check` runs everything CI runs, so a green local check means a green pipeline.

---

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Good first contributions: a GCP cost source, a CloudTrail change source, or new entries in [`data/service_map.yaml`](src/costdetective/data/service_map.yaml) for resource types we don't cover yet.

## License

MIT — see [LICENSE](LICENSE).
