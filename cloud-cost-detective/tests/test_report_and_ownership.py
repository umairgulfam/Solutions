from __future__ import annotations

import json
from datetime import timedelta

import pytest

from costdetective.engine import CorrelationEngine
from costdetective.models import Change, ServiceCost
from costdetective.ownership import OwnershipResolver
from costdetective.report import money, render, render_slack_blocks, render_text

# --- ownership -----------------------------------------------------------


def test_resource_tag_wins_over_everything(config, foundry_change):
    engine = CorrelationEngine(config)
    service = ServiceCost("AI Foundry", 17.0, 4.0, tags={"Team": "AI-R&D"})
    suspect = engine.score(service, foundry_change, foundry_change.timestamp + timedelta(hours=1))

    ownership = OwnershipResolver(config).resolve(service, [suspect])
    assert ownership.owner == "AI-R&D"
    assert ownership.source == "tag:Team"


def test_falls_back_to_config_by_service(config):
    config.data["ownership"]["by_service"] = {"api gateway": "platform-team"}
    service = ServiceCost("API Gateway", 35.0, 31.0)

    ownership = OwnershipResolver(config).resolve(service, [])
    assert ownership.owner == "platform-team"
    assert ownership.source == "config:by_service"


def test_by_path_maps_commit_files_to_a_team(config, now):
    config.data["ownership"]["by_path"] = {"ai-platform/": "AI-R&D"}
    change = Change(
        source="git",
        identifier="9f3ac21",
        title="feat(ai): add deployment",
        timestamp=now,
        author="s.raza",
        metadata={"files": ["ai-platform/foundry.tf"]},
    )
    from costdetective.models import Suspect

    ownership = OwnershipResolver(config).resolve(
        ServiceCost("AI Foundry", 17.0, 4.0), [Suspect(change=change, confidence=0.9)]
    )
    assert ownership.owner == "AI-R&D"
    assert ownership.source == "config:by_path"


def test_default_owner_when_nothing_matches(config):
    config.data["ownership"]["default"] = "finops"
    ownership = OwnershipResolver(config).resolve(ServiceCost("Glacier", 5.0, 1.0), [])
    assert ownership.owner == "finops"


# --- money formatting ----------------------------------------------------


@pytest.mark.parametrize(
    ("amount", "expected"),
    [(47.0, "+$47"), (4.0, "+$4"), (-12.5, "-$12.50"), (1234.0, "+$1,234"), (0.0, "+$0")],
)
def test_money_formatting(amount, expected):
    assert money(amount) == expected


def test_money_respects_currency():
    assert money(47.0, "EUR") == "+€47"
    assert money(47.0, "USD", signed=False) == "$47"


# --- renderers -----------------------------------------------------------


def test_text_report_matches_expected_shape(config, snapshot, foundry_change, now):
    result = CorrelationEngine(config).investigate(snapshot, [foundry_change], now=now)
    output = render_text(result)

    assert output.startswith("Today's increase: +$47")
    for section in ("Reason:", "Likely cause:", "Owner:", "Suggested action:"):
        assert section in output
    assert "AI Foundry      +$13" in output
    assert "AI-R&D" in output


def test_json_report_round_trips(config, snapshot, foundry_change, now):
    result = CorrelationEngine(config).investigate(snapshot, [foundry_change], now=now)
    payload = json.loads(render(result, fmt="json"))

    assert payload["snapshot"]["total_delta"] == 47.0
    assert payload["changes_considered"] == 1
    assert any(f["service"]["service"] == "AI Foundry" for f in payload["findings"])


def test_markdown_report_has_a_table(config, snapshot, foundry_change, now):
    result = CorrelationEngine(config).investigate(snapshot, [foundry_change], now=now)
    output = render(result, fmt="markdown")

    assert "| Service | Change |" in output
    assert "Review unused deployment." in output


def test_slack_payload_is_block_kit(config, snapshot, foundry_change, now):
    result = CorrelationEngine(config).investigate(snapshot, [foundry_change], now=now)
    payload = render_slack_blocks(result)

    assert payload["blocks"][0]["type"] == "header"
    assert "+$47" in payload["text"]


def test_unknown_format_is_rejected(config, snapshot, now):
    result = CorrelationEngine(config).investigate(snapshot, [], now=now)
    with pytest.raises(ValueError, match="unknown format"):
        render(result, fmt="yaml")


def test_report_handles_no_movement(config, snapshot, now):
    config.data["min_delta"] = 1000.0
    result = CorrelationEngine(config).investigate(snapshot, [], now=now)
    assert "No service moved" in render_text(result)
