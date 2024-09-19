"""Offline sources backed by a fixture file.

These exist so the tool is runnable — and testable in CI — with no cloud
credentials at all. ``costdetective report --demo`` uses them.
"""

from __future__ import annotations

import json
from datetime import date, datetime, timedelta
from importlib import resources
from pathlib import Path
from typing import Any

from costdetective.config import Config
from costdetective.models import Change, CostSnapshot, ServiceCost
from costdetective.sources.base import ChangeSource, CostSource, SourceError


def _load_fixture(config: Config) -> dict[str, Any]:
    path = config.get("demo.fixture")
    if path:
        file = Path(path).expanduser()
        if not file.is_file():
            raise SourceError(f"demo fixture not found: {file}")
        return json.loads(file.read_text(encoding="utf-8"))
    return json.loads(
        resources.files("costdetective.data")
        .joinpath("demo_scenario.json")
        .read_text(encoding="utf-8")
    )


def _anchor(fixture: dict[str, Any]) -> datetime:
    """Fixtures use relative offsets so the demo always looks like 'today'."""
    return datetime.combine(date.today(), datetime.min.time())


class DemoCostSource(CostSource):
    name = "demo"

    def fetch(self, days: int = 1) -> CostSnapshot:
        fixture = _load_fixture(self.config)
        today = date.today()
        services = [
            ServiceCost(
                service=item["service"],
                current=float(item["current"]),
                previous=float(item["previous"]),
                provider=item.get("provider", "demo"),
                account=item.get("account"),
                tags=item.get("tags", {}),
            )
            for item in fixture.get("services", [])
        ]
        return CostSnapshot(
            period_start=today - timedelta(days=days - 1),
            period_end=today,
            baseline_start=today - timedelta(days=days * 2 - 1),
            baseline_end=today - timedelta(days=days),
            currency=fixture.get("currency", "USD"),
            services=services,
            source="demo",
        )


class DemoChangeSource(ChangeSource):
    name = "demo"

    def fetch(self, since: datetime) -> list[Change]:
        fixture = _load_fixture(self.config)
        anchor = _anchor(fixture)
        changes: list[Change] = []
        for item in fixture.get("changes", []):
            offset_hours = float(item.get("hours_ago", 12))
            timestamp = anchor - timedelta(hours=offset_hours)
            change = Change(
                source=item.get("source", "demo"),
                identifier=item["identifier"],
                title=item["title"],
                timestamp=timestamp,
                action=item.get("action", "change"),
                author=item.get("author"),
                team=item.get("team"),
                resource_types=item.get("resource_types", []),
                services=item.get("services", []),
                url=item.get("url"),
                metadata=item.get("metadata", {}),
            )
            if change.timestamp >= since:
                changes.append(change)
        return changes
