"""Command line interface.

    costdetective report --demo
    costdetective report --source aws --days 1 --format markdown -o report.md
    costdetective report --source aws --fail-over 100      # exit 2 in CI
    costdetective explain "AI Foundry" --demo
    costdetective sources
    costdetective validate --config costdetective.yaml

Exit codes:
    0  success
    1  a runtime error (bad config, unreachable source)
    2  the increase breached ``--fail-over`` / ``thresholds.fail``
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timedelta
from pathlib import Path

from costdetective import __version__
from costdetective.config import ConfigError, load_config
from costdetective.engine import CorrelationEngine
from costdetective.models import Change, Investigation
from costdetective.report import money, render
from costdetective.servicemap import ServiceMap
from costdetective.sources import (
    ChangeSource,
    CostSource,
    SourceError,
    build_change_sources,
    build_cost_source,
    list_sources,
)

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_THRESHOLD = 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="costdetective",
        description="Explain why your cloud bill moved: cost deltas correlated with "
        "Terraform changes, cloud resources and git commits.",
    )
    parser.add_argument("--version", action="version", version=f"costdetective {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("-c", "--config", help="path to costdetective.yaml")
    common.add_argument("--source", help="cost source: demo, aws, azure, file")
    common.add_argument(
        "--change-source",
        action="append",
        dest="change_sources",
        help="change source (repeatable): terraform, git, demo",
    )
    common.add_argument("--demo", action="store_true", help="use the bundled offline scenario")
    common.add_argument("--days", type=int, default=None, help="days per comparison window")
    common.add_argument(
        "--window-hours",
        type=float,
        default=None,
        help="how far back to look for correlated changes",
    )
    common.add_argument(
        "--min-delta",
        type=float,
        default=None,
        help="ignore services that moved less than this",
    )
    common.add_argument("-v", "--verbose", action="store_true", help="show scoring reasons")

    report = sub.add_parser("report", parents=[common], help="produce a cost investigation")
    report.add_argument(
        "-f", "--format", default="text", choices=["text", "json", "markdown", "md"]
    )
    report.add_argument("-o", "--output", help="write to a file instead of stdout")
    report.add_argument("--slack", action="store_true", help="also post to the Slack webhook")
    report.add_argument(
        "--fail-over",
        type=float,
        default=None,
        help="exit 2 if the total increase exceeds this amount",
    )

    explain = sub.add_parser("explain", parents=[common], help="drill into one service")
    explain.add_argument("service", help='service name, e.g. "AI Foundry"')

    sub.add_parser("sources", help="list available cost and change sources")
    validate = sub.add_parser("validate", parents=[common], help="check configuration and access")
    validate.add_argument(
        "--check-access", action="store_true", help="also probe each source for credentials"
    )

    return parser


def _apply_overrides(config, args: argparse.Namespace):
    if getattr(args, "demo", False):
        config.data["cost_source"] = "demo"
        config.data["change_sources"] = ["demo"]
    if getattr(args, "source", None):
        config.data["cost_source"] = args.source
    if getattr(args, "change_sources", None):
        config.data["change_sources"] = args.change_sources
    if getattr(args, "window_hours", None) is not None:
        config.data["correlation_window_hours"] = args.window_hours
    if getattr(args, "min_delta", None) is not None:
        config.data["min_delta"] = args.min_delta
    return config


def _investigate(config, days: int) -> Investigation:
    cost_source = build_cost_source(config)
    snapshot = cost_source.fetch(days=days)

    window = timedelta(hours=float(config.get("correlation_window_hours", 72)))
    since = datetime.utcnow() - window

    changes: list[Change] = []
    errors: list[str] = []
    for source in build_change_sources(config):
        try:
            changes.extend(source.fetch(since=since))
        except SourceError as exc:
            errors.append(f"{source.name}: {exc}")

    for message in errors:
        print(f"warning: change source unavailable — {message}", file=sys.stderr)

    engine = CorrelationEngine(config, ServiceMap.load(config.get("service_map", {})))
    return engine.investigate(snapshot, changes)


def cmd_report(args: argparse.Namespace) -> int:
    config = _apply_overrides(load_config(args.config), args)
    days = args.days or int(config.get("lookback_days", 1))
    investigation = _investigate(config, days)

    output = render(investigation, fmt=args.format, verbose=args.verbose)

    if args.output:
        path = Path(args.output).expanduser()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(output + "\n", encoding="utf-8")
        print(f"wrote {path}", file=sys.stderr)
    else:
        print(output)

    if args.slack:
        from costdetective.notify import NotifyError, post_to_slack

        webhook = config.get("notify.slack_webhook")
        try:
            post_to_slack(
                investigation, webhook, mention=config.get("notify.mention_on_threshold")
            )
            print("posted to Slack", file=sys.stderr)
        except NotifyError as exc:
            print(f"error: slack delivery failed — {exc}", file=sys.stderr)
            return EXIT_ERROR

    limit = args.fail_over if args.fail_over is not None else config.get("thresholds.fail")
    if limit is not None and investigation.snapshot.total_delta > float(limit):
        currency = investigation.snapshot.currency
        print(
            f"error: increase {money(investigation.snapshot.total_delta, currency)} "
            f"exceeds threshold {money(float(limit), currency, signed=False)}",
            file=sys.stderr,
        )
        return EXIT_THRESHOLD

    return EXIT_OK


def cmd_explain(args: argparse.Namespace) -> int:
    config = _apply_overrides(load_config(args.config), args)
    config.data["min_delta"] = 0.0  # explain works even for tiny movements
    days = args.days or int(config.get("lookback_days", 1))
    investigation = _investigate(config, days)

    target = args.service.strip().lower()
    matches = [f for f in investigation.findings if f.service.service.lower() == target]
    if not matches:
        available = ", ".join(sorted(f.service.service for f in investigation.findings))
        print(
            f"no increase recorded for '{args.service}'."
            + (f" Services that moved: {available}" if available else ""),
            file=sys.stderr,
        )
        return EXIT_ERROR

    finding = matches[0]
    currency = investigation.snapshot.currency
    pct = finding.service.pct_change
    print(f"{finding.service.service}: {money(finding.service.delta, currency)}", end="")
    print(f" ({pct:+.1f}%)" if pct is not None else "")
    print(
        f"  {money(finding.service.previous, currency, signed=False)} -> "
        f"{money(finding.service.current, currency, signed=False)}"
    )
    print(f"  owner: {finding.owner}  [{finding.owner_source}]")
    print(f"  suggested action: {finding.suggested_action}")
    print()

    if not finding.suspects:
        print("  no correlated change found in the investigation window.")
        return EXIT_OK

    print("  suspects:")
    for rank, suspect in enumerate(finding.suspects, start=1):
        change = suspect.change
        print(
            f"   {rank}. [{change.source}] {change.identifier} — {change.title} "
            f"({suspect.confidence:.0%} {suspect.confidence_label})"
        )
        print(f"      when: {change.timestamp:%Y-%m-%d %H:%M}  author: {change.author or 'unknown'}")
        for reason in suspect.reasons:
            print(f"      - {reason}")
        if change.url:
            print(f"      {change.url}")
    return EXIT_OK


def cmd_sources(_: argparse.Namespace) -> int:
    registry = list_sources()
    print("cost sources:   " + ", ".join(registry["cost"]))
    print("change sources: " + ", ".join(registry["change"]))
    return EXIT_OK


def cmd_validate(args: argparse.Namespace) -> int:
    config = _apply_overrides(load_config(args.config), args)
    print(f"config file: {config.path or '(defaults only)'}")

    problems = config.validate()
    if problems:
        for problem in problems:
            print(f"  invalid: {problem}", file=sys.stderr)
        return EXIT_ERROR
    print("  configuration OK")

    if args.check_access:
        failed = False
        probes: list[CostSource | ChangeSource] = [
            build_cost_source(config),
            *build_change_sources(config),
        ]
        for source in probes:
            try:
                source.check()
                print(f"  {source.name}: reachable")
            except SourceError as exc:
                failed = True
                print(f"  {source.name}: {exc}", file=sys.stderr)
        if failed:
            return EXIT_ERROR
    return EXIT_OK


COMMANDS = {
    "report": cmd_report,
    "explain": cmd_explain,
    "sources": cmd_sources,
    "validate": cmd_validate,
}


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return COMMANDS[args.command](args)
    except (ConfigError, SourceError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_ERROR
    except KeyboardInterrupt:  # pragma: no cover
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
