"""Core data structures shared by every source, the engine and the renderers.

Everything here is a plain dataclass so the whole pipeline stays serialisable:
sources produce these, the engine consumes them, the renderers format them.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import date, datetime
from typing import Any


def _round(value: float) -> float:
    return round(float(value), 2)


@dataclass
class ServiceCost:
    """Spend for a single billable service across two comparable periods."""

    service: str
    current: float
    previous: float
    provider: str = "unknown"
    account: str | None = None
    tags: dict[str, str] = field(default_factory=dict)

    @property
    def delta(self) -> float:
        return _round(self.current - self.previous)

    @property
    def pct_change(self) -> float | None:
        if self.previous == 0:
            return None
        return _round((self.current - self.previous) / self.previous * 100)

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["delta"] = self.delta
        data["pct_change"] = self.pct_change
        return data


@dataclass
class CostSnapshot:
    """A day-over-day (or period-over-period) view of spend."""

    period_start: date
    period_end: date
    baseline_start: date
    baseline_end: date
    currency: str = "USD"
    services: list[ServiceCost] = field(default_factory=list)
    source: str = "unknown"

    @property
    def total_current(self) -> float:
        return _round(sum(s.current for s in self.services))

    @property
    def total_previous(self) -> float:
        return _round(sum(s.previous for s in self.services))

    @property
    def total_delta(self) -> float:
        return _round(self.total_current - self.total_previous)

    def increases(self, threshold: float = 0.0) -> list[ServiceCost]:
        """Services whose spend went up by more than ``threshold``."""
        risers = [s for s in self.services if s.delta > threshold]
        return sorted(risers, key=lambda s: s.delta, reverse=True)

    def to_dict(self) -> dict[str, Any]:
        return {
            "source": self.source,
            "currency": self.currency,
            "period": {
                "start": self.period_start.isoformat(),
                "end": self.period_end.isoformat(),
            },
            "baseline": {
                "start": self.baseline_start.isoformat(),
                "end": self.baseline_end.isoformat(),
            },
            "total_current": self.total_current,
            "total_previous": self.total_previous,
            "total_delta": self.total_delta,
            "services": [s.to_dict() for s in self.services],
        }


@dataclass
class Change:
    """Something that happened in the estate: a commit, an apply, a new resource."""

    source: str  # "terraform" | "git" | "cloud" | ...
    identifier: str  # commit sha, resource address, resource id
    title: str
    timestamp: datetime
    action: str = "change"  # create | update | delete | change
    author: str | None = None
    team: str | None = None
    resource_types: list[str] = field(default_factory=list)
    services: list[str] = field(default_factory=list)  # resolved canonical services
    url: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["timestamp"] = self.timestamp.isoformat()
        return data


@dataclass
class Suspect:
    """A change the engine believes is responsible for a cost movement."""

    change: Change
    confidence: float
    reasons: list[str] = field(default_factory=list)

    @property
    def confidence_label(self) -> str:
        if self.confidence >= 0.75:
            return "high"
        if self.confidence >= 0.45:
            return "medium"
        return "low"

    def to_dict(self) -> dict[str, Any]:
        return {
            "confidence": round(self.confidence, 3),
            "confidence_label": self.confidence_label,
            "reasons": self.reasons,
            "change": self.change.to_dict(),
        }


@dataclass
class Finding:
    """One service that moved, plus who did it and what to do about it."""

    service: ServiceCost
    suspects: list[Suspect] = field(default_factory=list)
    owner: str = "unassigned"
    owner_source: str = "default"
    suggested_action: str = "Review recent changes for this service."

    @property
    def likely_cause(self) -> str:
        if not self.suspects:
            return "No correlated change found in the investigation window."
        return self.suspects[0].change.title

    @property
    def confidence(self) -> float:
        return self.suspects[0].confidence if self.suspects else 0.0

    @property
    def impact_score(self) -> float:
        """How much this movement deserves the reader's attention.

        Three factors, multiplied:

        * **size** — the absolute delta, because dollars are the point.
        * **explainability** — a movement we can pin on a specific change is
          more actionable than one we cannot. Floored at 0.1 so a large
          unexplained movement still surfaces.
        * **anomaly** — relative change. A service going from $4 to $17 (+325%)
          is a far stronger signal than a mature service drifting +12%, even
          though the drift is worth more dollars. Capped at 3x so a service
          starting from near-zero cannot dominate on percentage alone.
        """
        anomaly = 1.0
        if self.service.pct_change is not None:
            anomaly = 1.0 + min(self.service.pct_change / 100.0, 2.0)
        return self.service.delta * max(self.confidence, 0.1) * anomaly

    def to_dict(self) -> dict[str, Any]:
        return {
            "service": self.service.to_dict(),
            "owner": self.owner,
            "owner_source": self.owner_source,
            "likely_cause": self.likely_cause,
            "confidence": round(self.confidence, 3),
            "suggested_action": self.suggested_action,
            "suspects": [s.to_dict() for s in self.suspects],
        }


@dataclass
class Investigation:
    """The full result: the snapshot, the findings, and the headline verdict."""

    snapshot: CostSnapshot
    findings: list[Finding] = field(default_factory=list)
    changes_considered: int = 0
    generated_at: datetime = field(default_factory=datetime.utcnow)

    @property
    def headline(self) -> Finding | None:
        """The movement most worth acting on — see :attr:`Finding.impact_score`.

        Deliberately not "the biggest number": the largest delta on a mature
        service is often just normal drift, while a smaller spike on a service
        that barely cost anything yesterday is the thing someone broke.
        """
        if not self.findings:
            return None
        return max(self.findings, key=lambda f: (f.impact_score, f.service.delta))

    def to_dict(self) -> dict[str, Any]:
        return {
            "generated_at": self.generated_at.isoformat(),
            "changes_considered": self.changes_considered,
            "snapshot": self.snapshot.to_dict(),
            "findings": [f.to_dict() for f in self.findings],
        }
