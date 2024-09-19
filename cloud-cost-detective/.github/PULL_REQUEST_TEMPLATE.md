## What this changes

<!-- One or two sentences. What problem does this solve? -->

## Why

<!-- Link the issue, or describe the situation that prompted it. -->

## How to verify

```bash
make check
costdetective report --demo
```

<!-- Add anything specific a reviewer should run. -->

## Checklist

- [ ] `make check` passes locally
- [ ] Tests cover the behaviour change (not just the lines)
- [ ] No new runtime dependency, or it is behind an optional extra
- [ ] No widened IAM permissions
- [ ] Docs updated if behaviour or config changed
- [ ] CHANGELOG.md updated under Unreleased
