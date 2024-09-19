"""Renderers.

``text`` is the terminal/Slack-code-block format from the original design:

    Today's increase: +$47

    Reason:
    EC2             +$12
    RDS             +$18
    API Gateway     +$4
    AI Foundry      +$13

    Likely cause:
    AI Foundry resource created yesterday.

    Owner:
    AI-R&D

    Suggested action:
    Review unused deployment.
"""

from __future__ import annotations

import json
from typing import Any

from costdetective.models import Investigation

_SYMBOLS = {"USD": "$", "EUR": "€", "GBP": "£", "PKR": "Rs ", "INR": "₹"}
_LABEL_WIDTH = 16


def money(amount: float, currency: str = "USD", signed: bool = True) -> str:
    symbol = _SYMBOLS.get(currency.upper(), f"{currency.upper()} ")
    magnitude = abs(amount)
    body = f"{magnitude:,.0f}" if magnitude == int(magnitude) else f"{magnitude:,.2f}"
    if not signed:
        return f"{symbol}{body}"
    sign = "+" if amount >= 0 else "-"
    return f"{sign}{symbol}{body}"


def render(investigation: Investigation, fmt: str = "text", verbose: bool = False) -> str:
    renderers = {
        "text": render_text,
        "json": render_json,
        "markdown": render_markdown,
        "md": render_markdown,
    }
    if fmt not in renderers:
        raise ValueError(f"unknown format '{fmt}'. Use: text, json, markdown")
    if fmt == "json":
        return render_json(investigation)
    return renderers[fmt](investigation, verbose=verbose)  # type: ignore[operator]


def render_text(investigation: Investigation, verbose: bool = False) -> str:
    snap = investigation.snapshot
    cur = snap.currency
    lines: list[str] = []

    period = "Today's" if (snap.period_end - snap.period_start).days <= 1 else "Period"
    lines.append(f"{period} increase: {money(snap.total_delta, cur)}")

    if not investigation.findings:
        lines.append("")
        lines.append("No service moved more than the reporting threshold.")
        return "\n".join(lines)

    lines.append("")
    lines.append("Reason:")
    for finding in investigation.findings:
        label = finding.service.service.ljust(_LABEL_WIDTH)
        lines.append(f"{label}{money(finding.service.delta, cur)}")

    headline = investigation.headline
    if headline is not None:
        lines.append("")
        lines.append("Likely cause:")
        cause = headline.likely_cause.rstrip(".")
        lines.append(f"{cause}.")
        if verbose and headline.suspects:
            lines.append(
                f"  confidence: {headline.confidence:.0%} ({headline.suspects[0].confidence_label})"
            )
            for reason in headline.suspects[0].reasons:
                lines.append(f"  - {reason}")

        lines.append("")
        lines.append("Owner:")
        lines.append(headline.owner)

        lines.append("")
        lines.append("Suggested action:")
        lines.append(headline.suggested_action)

    if verbose and len(investigation.findings) > 1:
        lines.append("")
        lines.append("Other movements:")
        for finding in investigation.findings:
            if finding is headline:
                continue
            lines.append(
                f"{finding.service.service.ljust(_LABEL_WIDTH)}"
                f"{money(finding.service.delta, cur)}  "
                f"owner={finding.owner}  cause={finding.likely_cause}"
            )

    return "\n".join(lines)


def render_markdown(investigation: Investigation, verbose: bool = False) -> str:
    snap = investigation.snapshot
    cur = snap.currency
    out: list[str] = []

    out.append(f"## Cloud cost report — {snap.period_end.isoformat()}")
    out.append("")
    out.append(
        f"**Change vs previous period: {money(snap.total_delta, cur)}** "
        f"({money(snap.total_previous, cur, signed=False)} → "
        f"{money(snap.total_current, cur, signed=False)})"
    )
    out.append("")

    if not investigation.findings:
        out.append("_No service moved more than the reporting threshold._")
        return "\n".join(out)

    out.append("| Service | Change | Likely cause | Owner | Confidence |")
    out.append("| --- | ---: | --- | --- | --- |")
    for f in investigation.findings:
        out.append(
            f"| {f.service.service} | {money(f.service.delta, cur)} | "
            f"{f.likely_cause} | {f.owner} | {f.confidence:.0%} |"
        )

    headline = investigation.headline
    if headline is not None:
        out.append("")
        out.append(f"### Suggested action — {headline.service.service}")
        out.append("")
        out.append(headline.suggested_action)
        if headline.suspects:
            out.append("")
            out.append("<details><summary>Why we think so</summary>")
            out.append("")
            for suspect in headline.suspects:
                link = (
                    f"[{suspect.change.identifier}]({suspect.change.url})"
                    if suspect.change.url
                    else f"`{suspect.change.identifier}`"
                )
                out.append(
                    f"- {link} — {suspect.change.title} "
                    f"({suspect.confidence:.0%} confidence)"
                )
                for reason in suspect.reasons:
                    out.append(f"  - {reason}")
            out.append("")
            out.append("</details>")

    out.append("")
    out.append(
        f"<sub>{investigation.changes_considered} changes considered · "
        f"generated {investigation.generated_at.strftime('%Y-%m-%d %H:%M UTC')} "
        f"by cloud-cost-detective</sub>"
    )
    return "\n".join(out)


def render_json(investigation: Investigation, verbose: bool = False) -> str:
    return json.dumps(investigation.to_dict(), indent=2, sort_keys=False)


def render_slack_blocks(investigation: Investigation) -> dict[str, Any]:
    """Slack Block Kit payload for an incoming webhook."""
    snap = investigation.snapshot
    cur = snap.currency
    headline = investigation.headline
    delta = snap.total_delta
    emoji = ":rotating_light:" if delta > 0 else ":white_check_mark:"

    blocks: list[dict[str, Any]] = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": f"{emoji} Cloud spend {money(delta, cur)} vs yesterday",
            },
        }
    ]

    if investigation.findings:
        rows = "\n".join(
            f"`{f.service.service.ljust(_LABEL_WIDTH)}` {money(f.service.delta, cur)}"
            for f in investigation.findings
        )
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": rows}})

    if headline is not None:
        fields = [
            {"type": "mrkdwn", "text": f"*Likely cause*\n{headline.likely_cause}"},
            {"type": "mrkdwn", "text": f"*Owner*\n{headline.owner}"},
            {"type": "mrkdwn", "text": f"*Confidence*\n{headline.confidence:.0%}"},
            {"type": "mrkdwn", "text": f"*Suggested action*\n{headline.suggested_action}"},
        ]
        blocks.append({"type": "section", "fields": fields})

    blocks.append(
        {
            "type": "context",
            "elements": [
                {
                    "type": "mrkdwn",
                    "text": (
                        f"{investigation.changes_considered} changes considered · "
                        f"source: {snap.source} · cloud-cost-detective"
                    ),
                }
            ],
        }
    )

    return {"text": f"Cloud spend {money(delta, cur)} vs yesterday", "blocks": blocks}
