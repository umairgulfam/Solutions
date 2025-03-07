import hashlib
from datetime import UTC, datetime

from garbage_collector.config import Settings
from garbage_collector.models import CloudResource, Finding, ResourceType


def _age_days(resource: CloudResource, now: datetime) -> int:
    if resource.created_at is None:
        return 0
    created = resource.created_at
    if created.tzinfo is None:
        created = created.replace(tzinfo=UTC)
    return max(0, (now - created).days)


def _fingerprint(resource: CloudResource, reason: str) -> str:
    value = f"{resource.provider}:{resource.account_id}:{resource.id}:{reason}"
    return hashlib.sha256(value.encode()).hexdigest()[:20]


def evaluate(
    resource: CloudResource, settings: Settings, now: datetime | None = None
) -> Finding | None:
    now = now or datetime.now(UTC)
    age = _age_days(resource, now)
    reason = ""
    evidence: list[str] = []
    confidence = 0

    if resource.resource_type == ResourceType.VM:
        cpu = resource.metrics.get("cpu_percent", 100)
        network = resource.metrics.get("network_mb_30d", 1)
        if age >= settings.idle_days and cpu < 2 and network < 1:
            reason = "Virtual machine has sustained near-zero utilization"
            evidence = [
                f"Average CPU: {cpu:.1f}%",
                f"Network traffic (30d): {network:.1f} MB",
                f"Age: {age} days",
            ]
            confidence = 92
    elif resource.resource_type in {ResourceType.PUBLIC_IP, ResourceType.DISK, ResourceType.NIC}:
        if resource.attached is False:
            reason = f"Unattached {resource.resource_type.value.replace('_', ' ')}"
            evidence = ["No parent resource or attachment was found", f"Age: {age} days"]
            confidence = 98
    elif resource.resource_type == ResourceType.SNAPSHOT and age >= settings.old_snapshot_days:
        reason = "Snapshot exceeds retention threshold"
        evidence = [f"Age: {age} days", f"Threshold: {settings.old_snapshot_days} days"]
        confidence = 88
    elif (
        resource.resource_type == ResourceType.LOAD_BALANCER
        and resource.metadata.get("backend_count", 1) == 0
    ):
        reason = "Load balancer has no registered backends"
        evidence = ["Registered backend count: 0"]
        confidence = 94
    elif resource.resource_type == ResourceType.DATABASE:
        connections = resource.metrics.get("connections_30d", 1)
        if resource.state.lower() in {"stopped", "deallocated"} or connections == 0:
            reason = "Database is stopped or has no recent connections"
            evidence = [f"State: {resource.state}", f"Connections (30d): {connections:.0f}"]
            confidence = 87
    elif resource.resource_type == ResourceType.NAT_GATEWAY:
        traffic = resource.metrics.get("bytes_30d", 1)
        if traffic == 0:
            reason = "NAT gateway has no observed traffic"
            evidence = ["Processed bytes (30d): 0"]
            confidence = 90
    elif resource.resource_type == ResourceType.CONTAINER_IMAGE:
        untagged = bool(resource.metadata.get("untagged", False))
        if untagged or age >= settings.old_image_days:
            reason = "Container image is untagged or beyond retention"
            evidence = [f"Untagged: {untagged}", f"Age: {age} days"]
            confidence = 85

    if not reason or resource.estimated_monthly_cost < settings.min_monthly_cost:
        return None
    return Finding(
        fingerprint=_fingerprint(resource, reason),
        resource=resource,
        reason=reason,
        evidence=evidence,
        confidence=confidence,
        estimated_monthly_savings=resource.estimated_monthly_cost,
    )


def scan_resources(resources: list[CloudResource], settings: Settings) -> list[Finding]:
    return [finding for resource in resources if (finding := evaluate(resource, settings))]
