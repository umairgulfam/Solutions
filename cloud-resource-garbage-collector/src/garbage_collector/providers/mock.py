from datetime import UTC, datetime, timedelta
from typing import Any

from garbage_collector.models import CloudResource, Provider, ResourceType
from garbage_collector.providers.base import CloudProvider


class MockProvider(CloudProvider):
    name = Provider.MOCK

    def inventory(self) -> list[CloudResource]:
        now = datetime.now(UTC)
        base: dict[str, Any] = {
            "provider": self.name,
            "account_id": "demo-account",
            "region": "us-east-1",
            "tags": {"owner": "finops@example.com"},
        }
        return [
            CloudResource(
                id="vm-old-01",
                name="legacy-reporting-vm",
                resource_type=ResourceType.VM,
                created_at=now - timedelta(days=300),
                metrics={"cpu_percent": 0.2, "network_mb_30d": 0},
                estimated_monthly_cost=86,
                **base,
            ),
            CloudResource(
                id="ip-01",
                name="unused-public-ip",
                resource_type=ResourceType.PUBLIC_IP,
                created_at=now - timedelta(days=60),
                attached=False,
                estimated_monthly_cost=3.65,
                **base,
            ),
            CloudResource(
                id="disk-01",
                name="orphaned-data-disk",
                resource_type=ResourceType.DISK,
                created_at=now - timedelta(days=120),
                attached=False,
                estimated_monthly_cost=24,
                **base,
            ),
            CloudResource(
                id="snap-01",
                name="pre-migration-snapshot",
                resource_type=ResourceType.SNAPSHOT,
                created_at=now - timedelta(days=200),
                estimated_monthly_cost=18,
                **base,
            ),
            CloudResource(
                id="nic-01",
                name="detached-nic",
                resource_type=ResourceType.NIC,
                created_at=now - timedelta(days=45),
                attached=False,
                estimated_monthly_cost=2,
                **base,
            ),
            CloudResource(
                id="lb-01",
                name="old-api-lb",
                resource_type=ResourceType.LOAD_BALANCER,
                metadata={"backend_count": 0},
                estimated_monthly_cost=22,
                **base,
            ),
            CloudResource(
                id="db-01",
                name="retired-test-db",
                resource_type=ResourceType.DATABASE,
                state="stopped",
                metrics={"connections_30d": 0},
                estimated_monthly_cost=110,
                **base,
            ),
            CloudResource(
                id="nat-01",
                name="unused-nat",
                resource_type=ResourceType.NAT_GATEWAY,
                metrics={"bytes_30d": 0},
                estimated_monthly_cost=35,
                **base,
            ),
            CloudResource(
                id="img-01",
                name="service:untagged",
                resource_type=ResourceType.CONTAINER_IMAGE,
                created_at=now - timedelta(days=180),
                metadata={"untagged": True},
                estimated_monthly_cost=4,
                **base,
            ),
        ]

    def delete(self, resource: CloudResource) -> str:
        return f"mock-deleted:{resource.id}"
