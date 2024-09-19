# Contributing

Thanks for considering a contribution. This project is small on purpose, and the bar for changes is mostly about keeping it that way.

## Getting set up

```bash
git clone https://github.com/your-org/cloud-cost-detective.git
cd cloud-cost-detective

python -m venv .venv && source .venv/bin/activate
make install          # editable install with dev extras

make check            # lint + types + tests, exactly what CI runs
costdetective report --demo
```

The whole suite runs offline against a bundled fixture. You never need cloud credentials to develop or test this project — if a change you are making requires them, that is a signal the abstraction is wrong.

## Before you open a PR

```bash
make format     # ruff --fix and ruff format
make check      # must be green
```

CI runs ruff, mypy, pytest on Python 3.10–3.12, a CLI smoke test, a packaging check and a Docker build. A green `make check` locally means a green pipeline.

## What good contributions look like

**Add a cost source.** Subclass `CostSource`, implement `fetch()`, register it in `sources/__init__.py`. GCP Billing is the most requested gap.

**Add a change source.** Subclass `ChangeSource`, implement `fetch(since)`. CloudTrail is the highest-value one — it would let the tool see resources created by hand in the console, which is currently a blind spot.

**Extend the service map.** `src/costdetective/data/service_map.yaml` maps resource types to billable services. It is incomplete by construction and every addition makes attribution better. This is a genuinely useful first PR and needs no architectural knowledge.

**Improve the scoring.** See [`docs/scoring.md`](docs/scoring.md) first. Changes to weights need a test that demonstrates the improvement on a concrete scenario, not just an assertion that it feels better.

## Expectations for changes

- **Tests for behaviour, not coverage.** A test should describe something a user would notice. `test_unlinked_change_scores_zero_even_if_recent` documents a real false positive we shipped and fixed; that is the kind worth writing.
- **Keep the runtime dependency list at one.** PyYAML is the only hard dependency, and cloud SDKs stay behind extras. If you need a library for a provider, put it in an optional extra and import it inside the method with a clear error when it is missing — `sources/aws.py` shows the pattern.
- **Never widen IAM.** The tool reads. It does not tag, terminate, resize or modify anything. A PR that adds a write permission needs a very good reason.
- **Comment the surprising parts only.** Explain why something is the way it is when it is not obvious — the leading record separator in the git source, the no-op filter in the Terraform parser. Do not narrate what the code plainly does.

## Reporting bugs

Include the command you ran, what you expected, what happened, and the output of:

```bash
costdetective --version
costdetective validate --check-access
```

**Redact before posting.** Account IDs, subscription IDs, resource ARNs, internal service names and webhook URLs all show up in this tool's output. Reproduce against `--demo` where you can.

## Security

Do not open a public issue for a security problem — see [SECURITY.md](SECURITY.md).

## Code of conduct

Be decent to each other. Assume good faith, critique the code rather than the person, and remember that the person on the other end is usually trying to fix something at the end of a long day.
