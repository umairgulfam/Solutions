# Contributing

1. Fork the repository and create a focused branch.
2. Install with `python -m pip install -e ".[all,dev]"`.
3. Add tests for behavior changes.
4. Run `make lint test security`.
5. Open a pull request using the template.

Provider collectors must be read-only. A new deletion implementation requires
an explicit feature flag, approval validation, an audit event, and tests.

