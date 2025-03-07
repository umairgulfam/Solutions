import secrets

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import HTMLResponse

from garbage_collector.config import get_settings
from garbage_collector.models import DecisionRequest, Finding, FindingStatus, ScanRequest
from garbage_collector.service import GarbageCollectorService
from garbage_collector.store import Store

settings = get_settings()
store = Store(settings.database_url)
service = GarbageCollectorService(settings, store)

app = FastAPI(title="Cloud Resource Garbage Collector", version="1.0.0", docs_url="/docs")


def require_api_key(x_api_key: str = Header(default="")) -> None:
    if not settings.api_key or not secrets.compare_digest(x_api_key, settings.api_key):
        raise HTTPException(status_code=401, detail="Invalid API key")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
def dashboard() -> str:
    with open(__file__.replace("api.py", "static/index.html"), encoding="utf-8") as handle:
        return handle.read()


@app.post("/api/v1/scans", response_model=list[Finding], dependencies=[Depends(require_api_key)])
def run_scan(request: ScanRequest) -> list[Finding]:
    try:
        return service.scan(request.providers)
    except RuntimeError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/v1/findings", response_model=list[Finding], dependencies=[Depends(require_api_key)])
def findings() -> list[Finding]:
    return store.list()


@app.post(
    "/api/v1/findings/{fingerprint}/{decision}",
    response_model=Finding,
    dependencies=[Depends(require_api_key)],
)
def decide(fingerprint: str, decision: FindingStatus, request: DecisionRequest) -> Finding:
    if decision not in {FindingStatus.APPROVED, FindingStatus.REJECTED, FindingStatus.IGNORED}:
        raise HTTPException(
            status_code=400, detail="Decision must be approved, rejected, or ignored"
        )
    try:
        return service.decide(fingerprint, decision, request.actor, request.comment)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Finding not found") from exc
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.post(
    "/api/v1/findings/{fingerprint}/delete",
    response_model=Finding,
    dependencies=[Depends(require_api_key)],
)
def delete(fingerprint: str, request: DecisionRequest) -> Finding:
    try:
        return service.delete(fingerprint, request.actor)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Finding not found") from exc
    except (ValueError, PermissionError) as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except NotImplementedError as exc:
        raise HTTPException(status_code=501, detail=str(exc)) from exc


@app.get("/api/v1/audit", dependencies=[Depends(require_api_key)])
def audit() -> list[dict[str, str]]:
    return store.audit()
