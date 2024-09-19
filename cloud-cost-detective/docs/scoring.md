# How the correlation works

The tool answers one question: **which change caused this cost movement?** It does that with a small, deliberately inspectable scoring model rather than anything statistical. You should be able to read a verdict and disagree with it.

## The pipeline

```
cost source  ──┐
               ├──►  engine.investigate()  ──►  findings  ──►  renderer
change sources ┘
```

1. A **cost source** returns a `CostSnapshot`: spend per service for a period and its comparable baseline.
2. **Change sources** return `Change` objects — Terraform plan/state entries and git commits.
3. The **engine** scores every change against every service that rose.
4. The **ownership resolver** attaches a human to each finding.
5. A **renderer** formats the result.

## The four signals

For each `(service, change)` pair:

| Signal | Weight | Fires when |
| --- | ---: | --- |
| Resource match | 0.50 | the change touches a resource type that bills to this service, per `data/service_map.yaml` |
| Keyword match | 0.25 | the service's keywords appear in the commit subject or touched file paths |
| Recency | 0.20 | scaled by `1 - (age / window)` — a change 1h old scores near the full 0.20, one at the window edge scores near 0 |
| Creation bonus | 0.15 | the change creates a resource rather than editing one |

Scores are summed and capped at 1.0. Anything at or above 0.20 becomes a *suspect*; the top three are kept per finding, ranked by confidence.

Confidence labels: **high** ≥ 0.75, **medium** ≥ 0.45, **low** below that.

## The two rules that matter more than the weights

### Timing alone is never evidence

A change with no resource-type match and no keyword match scores **exactly zero**, regardless of how recent it is or whether it created something.

This is not a tuning choice, it is a correctness one. Without it, a docs-only commit merged an hour ago outscores a Terraform change from yesterday that actually provisioned the resource. Early in development this tool blamed an API Gateway increase on an unrelated AI Foundry deployment purely because the deployment was recent — the kind of confident-but-wrong output that teaches people to ignore cost alerts. Recency and the creation bonus now only amplify a link that already exists; they cannot create one.

The honest output when nothing links is *"No correlated change found in the investigation window."* That is a useful answer. It tells you the cause is outside your IaC — usage growth, a price change, or something created by hand in the console.

### The headline is not the biggest number

Findings are ranked for the headline by:

```
impact_score = delta × max(confidence, 0.1) × anomaly
anomaly      = 1 + min(pct_change / 100, 2.0)      # capped at 3×
```

Three factors:

- **delta** — dollars are the point.
- **confidence** — a movement we can pin on a specific change is more actionable than one we cannot. Floored at 0.1 so a large unexplained movement still surfaces when nothing else is explained either.
- **anomaly** — relative change. A service going $4 → $17 (+325%) is a stronger signal than a mature service drifting +12%, even when the drift is worth more dollars. Capped at 3× so a service starting from near-zero cannot dominate on percentage alone.

In the bundled scenario RDS moves $18 and AI Foundry moves $13, yet AI Foundry is the headline: it is a 325% spike traceable to a specific new resource, while the RDS movement is a routine instance-class change. The bigger number is usually normal growth. The spike is usually the thing someone broke.

Every finding still appears in the `Reason:` list — the ranking decides what gets the headline, never what gets reported.

## Tuning it

The weights live at the top of `src/costdetective/engine.py`:

```python
W_RESOURCE = 0.50
W_KEYWORD  = 0.25
W_RECENCY  = 0.20
W_CREATE   = 0.15

MIN_SUSPECT_SCORE = 0.20
MAX_SUSPECTS_PER_FINDING = 3
```

Practical guidance:

- **Too many weak suspects?** Raise `MIN_SUSPECT_SCORE` to 0.35. This is usually better than lowering weights, since it filters without distorting the ranking.
- **Missing real causes?** Your service map is more likely the problem than the weights. Add the resource types you use under `service_map.resource_types` in your config.
- **Correlation window:** shorter than ~24h misses real causes because billing data lags reality by hours. Longer than ~96h starts producing coincidences. The 72h default is a compromise; tighten it if your team deploys constantly.
- **Noisy small movements:** raise `min_delta` rather than touching the model.

## Known limitations

- **Correlation is not causation.** The tool ranks plausibility, it does not prove anything. A high-confidence verdict on a coincidence is still a coincidence — which is why every score ships with its reasons.
- **Usage-driven spikes are invisible.** A traffic surge with no infrastructure change has no correlate, so it reports as unexplained. That is honest, not a bug.
- **Console changes are invisible** unless they leave a Terraform or git trace. A CloudTrail change source would close this gap and is the most valuable contribution someone could make.
- **Billing lag** means the most recent day is often incomplete. Compare full days.
- **Shared services muddy attribution.** A NAT gateway or shared cluster used by five teams gets one owner from its tags. Tag granularity is the fix, not tool logic.
