"""The correlation engine.

    cost increase + terraform changes + cloud resources + git commits = likely cause

For each service whose spend rose, every candidate change is scored on four
independent signals. Scores are additive and capped at 1.0:

  ==================  ======  =========================================
  signal              weight  meaning
  ==================  ======  =========================================
  resource match       0.50   the change touches a resource type that
                              bills to this service
  keyword match        0.25   the change text mentions the service
  recency              0.20   how close it is to the cost movement,
                              decaying linearly over the window
  creation bonus       0.15   new resources explain new spend better
                              than edits do
  ==================  ======  =========================================

The weights are deliberately boring and inspectable. Every point awarded is
recorded as a human-readable reason so an engineer can disagree with the tool.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from costdetective.config import Config
from costdetective.models import (
    Change,
    CostSnapshot,
    Finding,
    Investigation,
    ServiceCost,
    Suspect,
)
from costdetective.ownership import OwnershipResolver
from costdetective.servicemap import ServiceMap, default_map

W_RESOURCE = 0.50
W_KEYWORD = 0.25
W_RECENCY = 0.20
W_CREATE = 0.15

MIN_SUSPECT_SCORE = 0.20
MAX_SUSPECTS_PER_FINDING = 3


class CorrelationEngine:
    """Turns a cost snapshot plus a pile of changes into explained findings."""

    def __init__(self, config: Config, service_map: ServiceMap | None = None) -> None:
        self.config = config
        self.map = service_map or default_map()
        self.owners = OwnershipResolver(config)
        self.window = timedelta(hours=float(config.get("correlation_window_hours", 72)))
        self.min_delta = float(config.get("min_delta", 1.0))

    # -- scoring -----------------------------------------------------------

    def score(self, service: ServiceCost, change: Change, now: datetime) -> Suspect:
        score = 0.0
        reasons: list[str] = []
        canonical = self.map.normalise(service.service)
        linked = False

        mapped = {
            s
            for rt in change.resource_types
            if (s := self.map.service_for_resource_type(rt)) is not None
        } | set(change.services)

        if canonical in mapped:
            score += W_RESOURCE
            linked = True
            types = ", ".join(change.resource_types) or "declared service"
            reasons.append(f"touches {types}, which bills to {canonical}")

        text = f"{change.title} {' '.join(str(f) for f in change.metadata.get('files', []))}"
        if canonical in self.map.services_in_text(text):
            score += W_KEYWORD
            linked = True
            reasons.append(f"change text references {canonical}")

        age = now - change.timestamp
        if timedelta(0) <= age <= self.window:
            freshness = 1.0 - (age / self.window)
            score += W_RECENCY * freshness
            hours = max(int(age.total_seconds() // 3600), 0)
            reasons.append(f"landed {hours}h before the cost movement")

        if change.action == "create":
            score += W_CREATE
            reasons.append("creates new billable capacity")

        # Timing alone is not evidence. Without a resource-type or keyword link
        # to this service, every change that happened yesterday would look
        # guilty — so an unlinked change scores zero regardless of recency.
        if not linked:
            return Suspect(change=change, confidence=0.0, reasons=[])

        return Suspect(change=change, confidence=min(score, 1.0), reasons=reasons)

    # -- investigation -----------------------------------------------------

    def investigate(
        self,
        snapshot: CostSnapshot,
        changes: list[Change],
        now: datetime | None = None,
    ) -> Investigation:
        now = now or datetime.utcnow()
        in_window = [c for c in changes if now - c.timestamp <= self.window]
        findings: list[Finding] = []

        for service in snapshot.increases(threshold=self.min_delta):
            scored = [self.score(service, change, now) for change in in_window]
            suspects = sorted(
                (s for s in scored if s.confidence >= MIN_SUSPECT_SCORE),
                key=lambda s: s.confidence,
                reverse=True,
            )[:MAX_SUSPECTS_PER_FINDING]

            ownership = self.owners.resolve(service, suspects)
            resource = (
                suspects[0].change.metadata.get("address") or suspects[0].change.identifier
                if suspects
                else "the resource"
            )
            action = self.map.action_for(
                self.map.normalise(service.service),
                change_action=suspects[0].change.action if suspects else None,
                resource=resource,
            )

            findings.append(
                Finding(
                    service=service,
                    suspects=suspects,
                    owner=ownership.owner,
                    owner_source=ownership.source,
                    suggested_action=action,
                )
            )

        return Investigation(
            snapshot=snapshot,
            findings=findings,
            changes_considered=len(in_window),
            generated_at=now,
        )
