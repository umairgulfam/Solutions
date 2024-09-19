"""Post a report to a Slack incoming webhook.

Uses ``urllib`` so the core package stays dependency-light — no ``requests``
needed just to send one JSON body.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request

from costdetective.models import Investigation
from costdetective.report import render_slack_blocks


class NotifyError(RuntimeError):
    """The message could not be delivered."""


def post_to_slack(
    investigation: Investigation,
    webhook_url: str,
    mention: str | None = None,
    timeout: int = 15,
) -> None:
    if not webhook_url:
        raise NotifyError("no Slack webhook URL configured (notify.slack_webhook)")

    payload = render_slack_blocks(investigation)
    if mention:
        payload["blocks"].insert(
            1,
            {"type": "section", "text": {"type": "mrkdwn", "text": f"cc {mention}"}},
        )

    request = urllib.request.Request(
        webhook_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if response.status >= 300:
                raise NotifyError(f"Slack returned HTTP {response.status}")
    except urllib.error.HTTPError as exc:
        raise NotifyError(f"Slack returned HTTP {exc.code}: {exc.reason}") from exc
    except urllib.error.URLError as exc:
        raise NotifyError(f"could not reach Slack: {exc.reason}") from exc
