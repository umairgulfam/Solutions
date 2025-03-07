from garbage_collector.config import Settings
from garbage_collector.detector import scan_resources
from garbage_collector.models import Finding, FindingStatus, Provider
from garbage_collector.providers import get_provider
from garbage_collector.store import Store


class GarbageCollectorService:
    def __init__(self, settings: Settings, store: Store) -> None:
        self.settings = settings
        self.store = store

    def scan(self, providers: list[Provider]) -> list[Finding]:
        findings = []
        for provider_name in providers:
            provider = get_provider(provider_name)
            findings.extend(scan_resources(provider.inventory(), self.settings))
        self.store.upsert(findings)
        return findings

    def decide(self, fingerprint: str, status: FindingStatus, actor: str, comment: str) -> Finding:
        current = self.store.get(fingerprint)
        if current is None:
            raise KeyError(fingerprint)
        allowed = {
            FindingStatus.PENDING: {
                FindingStatus.APPROVED,
                FindingStatus.REJECTED,
                FindingStatus.IGNORED,
            },
            FindingStatus.APPROVED: {FindingStatus.REJECTED},
        }
        if status not in allowed.get(current.status, set()):
            raise ValueError(f"Cannot transition {current.status} to {status}")
        return self.store.transition(fingerprint, status, actor, comment)

    def delete(self, fingerprint: str, actor: str) -> Finding:
        finding = self.store.get(fingerprint)
        if finding is None:
            raise KeyError(fingerprint)
        if finding.status != FindingStatus.APPROVED:
            raise ValueError("Finding must be approved before deletion")
        if not self.settings.enable_deletion:
            raise PermissionError("Deletion is disabled; set CRGC_ENABLE_DELETION=true")
        provider = get_provider(finding.resource.provider)
        try:
            provider.delete(finding.resource)
        except Exception as exc:
            self.store.transition(fingerprint, FindingStatus.FAILED, actor, str(exc))
            raise
        return self.store.transition(
            fingerprint, FindingStatus.DELETED, actor, "Provider confirmed deletion"
        )
