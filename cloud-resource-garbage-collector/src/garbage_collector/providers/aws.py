from typing import Any

from garbage_collector.models import CloudResource, Provider, ResourceType
from garbage_collector.providers.base import CloudProvider


class AWSProvider(CloudProvider):
    name = Provider.AWS

    def __init__(self, session: Any | None = None) -> None:
        if session is None:
            try:
                import boto3
            except ImportError as exc:
                raise RuntimeError("Install the AWS extra: pip install '.[aws]'") from exc
            session = boto3.Session()
        self.session = session

    @staticmethod
    def _tags(items: list[dict[str, str]] | None) -> dict[str, str]:
        return {item["Key"]: item["Value"] for item in items or []}

    def inventory(self) -> list[CloudResource]:
        sts = self.session.client("sts")
        account = sts.get_caller_identity()["Account"]
        regions = [
            r["RegionName"] for r in self.session.client("ec2").describe_regions()["Regions"]
        ]
        resources: list[CloudResource] = []
        for region in regions:
            ec2 = self.session.client("ec2", region_name=region)
            for volume in ec2.describe_volumes(
                Filters=[{"Name": "status", "Values": ["available"]}]
            )["Volumes"]:
                resources.append(
                    CloudResource(
                        id=volume["VolumeId"],
                        provider=self.name,
                        account_id=account,
                        region=region,
                        resource_type=ResourceType.DISK,
                        name=volume["VolumeId"],
                        created_at=volume.get("CreateTime"),
                        tags=self._tags(volume.get("Tags")),
                        attached=False,
                        estimated_monthly_cost=float(volume.get("Size", 0)) * 0.08,
                    )
                )
            for address in ec2.describe_addresses().get("Addresses", []):
                if not address.get("AssociationId"):
                    resources.append(
                        CloudResource(
                            id=address.get("AllocationId", address["PublicIp"]),
                            provider=self.name,
                            account_id=account,
                            region=region,
                            resource_type=ResourceType.PUBLIC_IP,
                            name=address["PublicIp"],
                            tags=self._tags(address.get("Tags")),
                            attached=False,
                            estimated_monthly_cost=3.65,
                        )
                    )
            for snapshot in ec2.describe_snapshots(OwnerIds=["self"])["Snapshots"]:
                resources.append(
                    CloudResource(
                        id=snapshot["SnapshotId"],
                        provider=self.name,
                        account_id=account,
                        region=region,
                        resource_type=ResourceType.SNAPSHOT,
                        name=snapshot.get("Description") or snapshot["SnapshotId"],
                        created_at=snapshot.get("StartTime"),
                        tags=self._tags(snapshot.get("Tags")),
                        estimated_monthly_cost=float(snapshot.get("VolumeSize", 0)) * 0.05,
                    )
                )
        return resources
