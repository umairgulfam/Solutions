from datetime import UTC, datetime
from enum import StrEnum
from typing import Any

from pydantic import BaseModel, Field


class Provider(StrEnum):
    AWS = "aws"
    AZURE = "azure"
    GCP = "gcp"
    MOCK = "mock"


class ResourceType(StrEnum):
    VM = "virtual_machine"
    PUBLIC_IP = "public_ip"
    DISK = "disk"
    SNAPSHOT = "snapshot"
    NIC = "network_interface"
    LOAD_BALANCER = "load_balancer"
    DATABASE = "database"
    NAT_GATEWAY = "nat_gateway"
    CONTAINER_IMAGE = "container_image"


class FindingStatus(StrEnum):
    PENDING = "pending"
    APPROVED = "approved"
    REJECTED = "rejected"
    IGNORED = "ignored"
    DELETED = "deleted"
    FAILED = "failed"


class CloudResource(BaseModel):
    id: str
    provider: Provider
    account_id: str
    region: str
    resource_type: ResourceType
    name: str
    created_at: datetime | None = None
    tags: dict[str, str] = Field(default_factory=dict)
    metrics: dict[str, float] = Field(default_factory=dict)
    state: str = "unknown"
    attached: bool | None = None
    estimated_monthly_cost: float = 0.0
    metadata: dict[str, Any] = Field(default_factory=dict)

    @property
    def owner(self) -> str:
        for key in ("owner", "Owner", "managed-by", "ManagedBy"):
            if value := self.tags.get(key):
                return value
        return "unassigned"


class Finding(BaseModel):
    fingerprint: str
    resource: CloudResource
    reason: str
    evidence: list[str]
    confidence: int = Field(ge=0, le=100)
    estimated_monthly_savings: float = Field(ge=0)
    detected_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
    status: FindingStatus = FindingStatus.PENDING


class DecisionRequest(BaseModel):
    actor: str = Field(min_length=2, max_length=100)
    comment: str = Field(default="", max_length=500)


class ScanRequest(BaseModel):
    providers: list[Provider] = Field(default_factory=lambda: [Provider.MOCK])
