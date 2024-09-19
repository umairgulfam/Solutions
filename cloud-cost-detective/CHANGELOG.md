# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-09-04

### Added
- Correlation engine scoring cost movements against Terraform changes and git
  commits on four weighted signals, with human-readable reasons attached to
  every score.
- Cost sources for AWS Cost Explorer and Azure Cost Management, plus a bundled
  offline demo fixture so the tool runs with no credentials.
- Change sources for Terraform (plan and state JSON, walking child modules) and
  git (extracts resource declarations from the added lines of `.tf` diffs).
- Ownership resolution with a seven-step fallback chain from resource tags
  through config maps to commit authors.
- Renderers for text, JSON, Markdown and Slack Block Kit.
- `report`, `explain`, `sources` and `validate` CLI commands.
- `--fail-over` threshold gating, exiting 2 so CI can gate on cost.
- Deployment assets: Dockerfile, Kubernetes CronJob, Terraform for a
  least-privilege OIDC/IRSA role, and three GitHub Actions workflows.

### Fixed
- Timing alone no longer counts as evidence. A change with no resource-type or
  keyword link to a service now scores zero regardless of recency — previously
  an unrelated recent deployment could be blamed for any increase.
- The git source placed its record separator after the commit header, so
  `--name-only` filenames were attributed to the following commit. Every commit
  reported an empty file list as a result.
- The headline finding is now ranked by `delta x confidence x anomaly` rather
  than raw delta, so a large routine drift no longer outranks a small,
  explainable spike.
- Whole-dollar amounts render as `+$4` rather than `+$4.00`.

[Unreleased]: https://github.com/your-org/cloud-cost-detective/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/your-org/cloud-cost-detective/releases/tag/v0.3.0
