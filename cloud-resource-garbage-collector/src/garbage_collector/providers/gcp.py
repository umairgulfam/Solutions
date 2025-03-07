import os
from typing import Any

from garbage_collector.models import CloudResource, Provider, ResourceType
from garbage_collector.providers.base import CloudProvider

ASSET_MAP = {
    "compute.googleapis.com/Disk": ResourceType.DISK,
    "compute.googleapis.com/Snapshot": ResourceType.SNAPSHOT,
    "compute.googleapis.com/Address": ResourceType.PUBLIC_IP,
    "compute.googleapis.com/ForwardingRule": ResourceType.LOAD_BALANCER,
    "compute.googleapis.com/Router": ResourceType.NAT_GATEWAY,
}


class GCPProvider(CloudProvider):
    name = Provider.GCP

    def __init__(self, client: Any | None = None) -> None:
        if client is None:
            try:
                from google.cloud import asset_v1
            except ImportError as exc:
                raise RuntimeError("Install the GCP extra: pip install '.[gcp]'") from exc
            client = asset_v1.AssetServiceClient()
        self.client = client

    def inventory(self) -> list[CloudResource]:
        project = os.getenv("GOOGLE_CLOUD_PROJECT")
        if not project:
            raise RuntimeError("Set GOOGLE_CLOUD_PROJECT")
        response = self.client.list_assets(
            request={
                "parent": f"projects/{project}",
                "asset_types": list(ASSET_MAP),
                "content_type": "RESOURCE",
            }
        )
        resources = []
        for asset in response:
            data = dict(asset.resource.data) if asset.resource else {}
            users = data.get("users", [])
            attached = bool(users) if ASSET_MAP[asset.asset_type] == ResourceType.DISK else None
            resources.append(
                CloudResource(
                    id=asset.name,
                    provider=self.name,
                    account_id=project,
                    region=str(data.get("region") or data.get("zone") or "global"),
                    resource_type=ASSET_MAP[asset.asset_type],
                    name=asset.name.rsplit("/", 1)[-1],
                    created_at=getattr(asset, "update_time", None),
                    tags=data.get("labels", {}),
                    attached=attached,
                    estimated_monthly_cost=1.0,
                    metadata=data,
                )
            )
        return resources
