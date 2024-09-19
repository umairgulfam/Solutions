from __future__ import annotations

from datetime import timedelta

from costdetective.engine import CorrelationEngine
from costdetective.models import Change, ServiceCost


def test_resource_type_match_drives_confidence(config, snapshot, foundry_change, now):
    engine = CorrelationEngine(config)
    foundry = next(s for s in snapshot.services if s.service == "AI Foundry")
    suspect = engine.score(foundry, foundry_change, now)

    assert suspect.confidence > 0.75
    assert suspect.confidence_label == "high"
    assert any("azurerm_cognitive_deployment" in r for r in suspect.reasons)


def test_unlinked_change_scores_zero_even_if_recent(config, snapshot, unrelated_change, now):
    """Timing alone must never accuse a change — this was a real false positive."""
    engine = CorrelationEngine(config)
    api_gw = next(s for s in snapshot.services if s.service == "API Gateway")
    suspect = engine.score(api_gw, unrelated_change, now)

    assert suspect.confidence == 0.0
    assert suspect.reasons == []


def test_recency_decays_over_the_window(config, snapshot, now):
    engine = CorrelationEngine(config)
    ec2 = next(s for s in snapshot.services if s.service == "EC2")

    def at(hours: float) -> float:
        # Deliberately no keyword hit and no create bonus, so the score stays
        # below the 1.0 cap and the recency term is the only thing varying.
        change = Change(
            source="terraform",
            identifier="module.web.main",
            title="capacity adjustment",
            timestamp=now - timedelta(hours=hours),
            action="update",
            resource_types=["aws_instance"],
        )
        return engine.score(ec2, change, now).confidence

    assert at(1) > at(24) > at(70)


def test_investigation_skips_flat_and_falling_services(config, snapshot, foundry_change, now):
    engine = CorrelationEngine(config)
    result = engine.investigate(snapshot, [foundry_change], now=now)

    moved = {f.service.service for f in result.findings}
    assert "S3" not in moved  # flat
    assert moved == {"EC2", "RDS", "API Gateway", "AI Foundry"}


def test_min_delta_filters_small_movements(config, snapshot, now):
    config.data["min_delta"] = 12.5
    engine = CorrelationEngine(config)
    result = engine.investigate(snapshot, [], now=now)

    assert {f.service.service for f in result.findings} == {"RDS", "AI Foundry"}


def test_changes_outside_window_are_ignored(config, snapshot, now):
    config.data["correlation_window_hours"] = 12
    stale = Change(
        source="terraform",
        identifier="aws_db_instance.orders",
        title="RDS instance resized",
        timestamp=now - timedelta(hours=48),
        action="update",
        resource_types=["aws_db_instance"],
    )
    engine = CorrelationEngine(config)
    result = engine.investigate(snapshot, [stale], now=now)

    assert result.changes_considered == 0
    rds = next(f for f in result.findings if f.service.service == "RDS")
    assert rds.suspects == []


def test_headline_prefers_explained_anomaly_over_biggest_number(
    config, snapshot, foundry_change, now
):
    """RDS moves more dollars, but AI Foundry is the anomaly we can explain."""
    rds_change = Change(
        source="terraform",
        identifier="aws_db_instance.orders",
        title="RDS instance class changed",
        timestamp=now - timedelta(hours=20),
        action="update",
        resource_types=["aws_db_instance"],
    )
    engine = CorrelationEngine(config)
    result = engine.investigate(snapshot, [foundry_change, rds_change], now=now)

    assert result.headline is not None
    assert result.headline.service.service == "AI Foundry"
    assert result.headline.likely_cause == "AI Foundry resource created yesterday"


def test_suggested_action_is_service_specific(config, snapshot, foundry_change, now):
    engine = CorrelationEngine(config)
    result = engine.investigate(snapshot, [foundry_change], now=now)
    foundry = next(f for f in result.findings if f.service.service == "AI Foundry")

    assert foundry.suggested_action == "Review unused deployment."


def test_suspects_are_ranked_and_capped(config, now):
    service = ServiceCost("EC2", current=100.0, previous=10.0, provider="aws")
    changes = [
        Change(
            source="git",
            identifier=f"sha{i}",
            title="EC2 instance added",
            timestamp=now - timedelta(hours=i),
            action="create",
            resource_types=["aws_instance"],
        )
        for i in range(1, 8)
    ]
    engine = CorrelationEngine(config)
    result = engine.investigate(_snapshot_with(service), changes, now=now)
    finding = result.findings[0]

    assert len(finding.suspects) <= 3
    confidences = [s.confidence for s in finding.suspects]
    assert confidences == sorted(confidences, reverse=True)


def _snapshot_with(service: ServiceCost):
    from datetime import date

    from costdetective.models import CostSnapshot

    today = date(2026, 9, 3)
    return CostSnapshot(
        period_start=today,
        period_end=today,
        baseline_start=today,
        baseline_end=today,
        services=[service],
        source="test",
    )
