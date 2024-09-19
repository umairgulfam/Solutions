# Examples

| File | What it is |
| --- | --- |
| `terraform-plan.json` | A trimmed `terraform show -json tfplan` output, usable as a real input |
| `custom-scenario.json` | A cost fixture in the format the demo source expects |

## Run against the sample Terraform plan

```bash
costdetective report \
  --source demo \
  --change-source terraform \
  --config /dev/null 2>/dev/null || true

COSTDETECTIVE_TERRAFORM_PLAN=examples/terraform-plan.json \
  costdetective report --source demo --change-source terraform --verbose
```

## Build your own scenario

Point the demo source at your own fixture to model a situation without touching
a cloud account — useful for testing your ownership config or a new service map
entry before it hits production:

```yaml
# costdetective.yaml
cost_source: demo
change_sources: [demo]
demo:
  fixture: examples/custom-scenario.json
```

```bash
costdetective report --verbose
```

`hours_ago` in the fixture is relative to midnight today, so the scenario always
looks current no matter when you run it.
