import os
from typing import Any

from garbage_collector.models import CloudResource, Provider, ResourceType
from garbage_collector.providers.base import CloudProvider

TYPE_MAP = {
    "microsoft.compute/disks": ResourceType.DISK,
    "microsoft.compute/snapshots": ResourceType.SNAPSHOT,
    "microsoft.network/publicipaddresses": ResourceType.PUBLIC_IP,
    "microsoft.network/networkinterfaces": ResourceType.NIC,
    "microsoft.network/loadbalancers": ResourceType.LOAD_BALANCER,
    "microsoft.network/natgateways": ResourceType.NAT_GATEWAY,
}


class AzureProvider(CloudProvider):
    name = Provider.AZURE

    def __init__(self, client: Any | None = None) -> None:
        if client is None:
            try:
                from azure.identity import DefaultAzureCredential
                from azure.mgmt.resourcegraph import ResourceGraphClient
            except ImportError as exc:
                raise RuntimeError("Install the Azure extra: pip install '.[azure]'") from exc
            client = ResourceGraphClient(DefaultAzureCredential())
        self.client = client

    def inventory(self) -> list[CloudResource]:
        try:
            from azure.mgmt.resourcegraph.models import QueryRequest
        except ImportError as exc:
            raise RuntimeError("Install the Azure extra: pip install '.[azure]'") from exc
        subscriptions = [
            x.strip() for x in os.getenv("AZURE_SUBSCRIPTION_IDS", "").split(",") if x.strip()
        ]
        if not subscriptions:
            raise RuntimeError("Set AZURE_SUBSCRIPTION_IDS to one or more subscription IDs")
        types = ", ".join(f"'{item}'" for item in TYPE_MAP)
        query = (
            f"Resources | where type in~ ({types}) "
            "| project id, name, type, location, subscriptionId, tags, properties"
        )
        response = self.client.resources(QueryRequest(subscriptions=subscriptions, query=query))
        resources = []
        for row in response.data:
            resource_type = TYPE_MAP[row["type"].lower()]
            properties = row.get("properties") or {}
            attached = None
            if resource_type == ResourceType.DISK:
                attached = bool(properties.get("managedBy"))
            elif resource_type in {ResourceType.PUBLIC_IP, ResourceType.NIC}:
                attached = bool(
                    properties.get("ipConfiguration") or properties.get("virtualMachine")
                )
            resources.append(
                CloudResource(
                    id=row["id"],
                    provider=self.name,
                    account_id=row["subscriptionId"],
                    region=row.get("location", "global"),
                    resource_type=resource_type,
                    name=row["name"],
                    tags=row.get("tags") or {},
                    attached=attached,
                    estimated_monthly_cost=1.0,
                    metadata=properties,
                )
            )
        return resources
