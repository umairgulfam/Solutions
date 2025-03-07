from fastapi.testclient import TestClient

from garbage_collector.api import app


def test_health():
    response = TestClient(app).get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_findings_requires_key():
    response = TestClient(app).get("/api/v1/findings")
    assert response.status_code == 401
