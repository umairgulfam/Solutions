from __future__ import annotations

from datetime import date, datetime, timedelta

import pytest

from costdetective.config import DEFAULTS, Config
from costdetective.models import Change, CostSnapshot, ServiceCost


@pytest.fixture
def config() -> Config:
    data = {k: (dict(v) if isinstance(v, dict) else v) for k, v in DEFAULTS.items()}
    return Config(data=data)


@pytest.fixture
def now() -> datetime:
    return datetime(2026, 9, 3, 9, 0, 0)


@pytest.fixture
def snapshot() -> CostSnapshot:
    today = date(2026, 9, 3)
    return CostSnapshot(
        period_start=today,
        period_end=today,
        baseline_start=today - timedelta(days=1),
        baseline_end=today - timedelta(days=1),
        currency="USD",
        source="test",
        services=[
            ServiceCost("EC2", current=222.0, previous=210.0, provider="aws"),
            ServiceCost("RDS", current=166.0, previous=148.0, provider="aws"),
            ServiceCost("API Gateway", current=35.0, previous=31.0, provider="aws"),
            ServiceCost(
                "AI Foundry",
                current=17.0,
                previous=4.0,
                provider="azure",
                tags={"Team": "AI-R&D"},
            ),
            ServiceCost("S3", current=44.0, previous=44.0, provider="aws"),
        ],
    )


@pytest.fixture
def foundry_change(now: datetime) -> Change:
    return Change(
        source="terraform",
        identifier="azurerm_cognitive_deployment.gpt4o_rnd",
        title="AI Foundry resource created yesterday",
        timestamp=now - timedelta(hours=26),
        action="create",
        author="s.raza",
        team="AI-R&D",
        resource_types=["azurerm_cognitive_deployment"],
    )


@pytest.fixture
def unrelated_change(now: datetime) -> Change:
    return Change(
        source="git",
        identifier="c07e5b8",
        title="docs: update runbook links",
        timestamp=now - timedelta(hours=2),
        action="create",
        author="j.doe",
    )
