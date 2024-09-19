# Runbook: responding to a cost alert

For whoever picks up the morning report or a threshold breach.

## 1. Establish whether it is real

Billing data lags reality by several hours, and the most recent day is often
incomplete. Before escalating anything:

```bash
costdetective report --source aws --days 1 --verbose
```

If the increase is under your `min_delta` per service and only shows in the
total, it is probably rounding and lag. Compare full days rather than partial
ones. A "drop" reported before mid-morning is almost always incomplete data,
not a saving.

## 2. Read the confidence, not just the verdict

```bash
costdetective explain "AI Foundry" --verbose
```

| Confidence | What it means | What to do |
| --- | --- | --- |
| **high** (≥75%) | resource type matches and the change is recent | Go straight to the named resource |
| **medium** (45–74%) | partial link, usually keyword-only | Verify before messaging the owner |
| **low** (<45%) | weak link | Treat as a hint; investigate independently |
| **no suspects** | nothing in IaC correlates | See step 4 |

The reasons under each suspect tell you *why* it scored what it did. If the
only reason is a keyword match on a commit subject, that is a guess, not a
finding.

## 3. Contact the owner

The `owner` field carries its provenance in `owner_source`:

- `tag:Team` — from the billed resource's own tags. Trustworthy.
- `terraform:tag:Team` — from the suspected resource's tags. Trustworthy.
- `config:by_service` / `config:by_path` — from your config. As accurate as
  your config is current.
- `git:author` — whoever wrote the commit. This is *who changed it*, which is
  not always *who owns it*. Check before assigning blame.
- `default` — nobody claimed it. This is the real problem to fix.

A high rate of `default` owners means your tagging is the issue, not the tool.

## 4. When nothing correlates

`No correlated change found` is a real answer, not a failure. It narrows things:

- **Usage growth.** Traffic rose without an infrastructure change. Check
  request counts, data transfer and invocation metrics.
- **Console changes.** Someone created a resource by hand, so it left no
  Terraform or git trace. Check CloudTrail directly.
- **Price or commitment changes.** A reservation or savings plan expired, or a
  discount lapsed. Check the billing console.
- **Data-driven billing.** S3, CloudWatch and NAT gateways bill on volume.
  Storage grows without anyone deploying anything — check retention policies.
- **The window was too short.** A resource created four days ago may only now
  be showing full-day charges:

  ```bash
  costdetective report --source aws --window-hours 168 --verbose
  ```

## 5. Common causes, in rough order of frequency

| Symptom | Usual cause |
| --- | --- |
| CloudWatch creeping up steadily | log group with no retention policy |
| NAT gateway spike | chatty cross-AZ or egress traffic, often a new service |
| RDS step change | instance class change or a read replica left running |
| EC2 step change | ASG desired capacity raised, or an oversized instance type |
| AI/ML service spike from near-zero | an experiment deployment nobody tore down |
| S3 growth with no deploy | lifecycle rules missing on a new bucket |
| API Gateway spike | retry loop or a cache that stopped working |

## 6. Escalating

Include in the ticket:

```bash
costdetective report --source aws --verbose > report.txt
costdetective report --source aws --format json > report.json
```

Attach both. The JSON carries the full suspect list and confidence scores that
the text summary omits.

**Redact first.** Reports contain account IDs, resource addresses, internal
service names and commit authors.

## 7. If the tool itself is broken

```bash
costdetective validate --check-access
```

Common failures:

- `ce:GetCostAndUsage` denied — the role lost its policy, or you assumed the
  wrong one. See `deploy/terraform`.
- `terraform show failed` — state is locked or the backend is unreachable. The
  run continues with git alone; it does not fail outright.
- `does not look like a git repository` — the CronJob or CI job did a shallow
  clone. It needs `fetch-depth: 0`.
- Slack delivery failed — the webhook was rotated or revoked.
