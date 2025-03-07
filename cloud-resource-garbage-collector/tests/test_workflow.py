import pytest

from garbage_collector.models import FindingStatus, Provider


def test_approval_workflow(service):
    finding = service.scan([Provider.MOCK])[0]
    approved = service.decide(finding.fingerprint, FindingStatus.APPROVED, "reviewer", "safe")
    assert approved.status == FindingStatus.APPROVED
    with pytest.raises(PermissionError):
        service.delete(finding.fingerprint, "operator")


def test_cannot_delete_pending(service):
    finding = service.scan([Provider.MOCK])[0]
    with pytest.raises(ValueError, match="approved"):
        service.delete(finding.fingerprint, "operator")


def test_ignore_is_a_terminal_decision(service):
    finding = service.scan([Provider.MOCK])[0]
    service.decide(finding.fingerprint, FindingStatus.IGNORED, "owner", "required")
    with pytest.raises(ValueError):
        service.decide(finding.fingerprint, FindingStatus.APPROVED, "reviewer", "changed")


def test_mock_delete_after_approval(service):
    finding = service.scan([Provider.MOCK])[0]
    service.decide(finding.fingerprint, FindingStatus.APPROVED, "reviewer", "safe")
    service.settings.enable_deletion = True
    deleted = service.delete(finding.fingerprint, "operator")
    assert deleted.status == FindingStatus.DELETED
    assert [e["action"] for e in service.store.audit(finding.fingerprint)] == [
        "deleted",
        "approved",
    ]
