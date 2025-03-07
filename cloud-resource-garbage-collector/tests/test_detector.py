from datetime import UTC, datetime, timedelta

from garbage_collector.detector import evaluate, scan_resources
from garbage_collector.models import CloudResource, Provider, ResourceType
from garbage_collector.providers.mock import MockProvider


def test_mock_inventory_covers_all_resource_types(settings):
    resources = MockProvider().inventory()
    assert {resource.resource_type for resource in resources} == set(ResourceType)
    assert len(scan_resources(resources, settings)) == 9


def test_active_vm_is_not_flagged(settings):
    vm = CloudResource(
        id="vm",
        provider=Provider.AWS,
        account_id="1",
        region="us-east-1",
        resource_type=ResourceType.VM,
        name="active",
        created_at=datetime.now(UTC) - timedelta(days=100),
        metrics={"cpu_percent": 40, "network_mb_30d": 500},
        estimated_monthly_cost=100,
    )
    assert evaluate(vm, settings) is None


def test_low_cost_resource_is_ignored(settings):
    disk = CloudResource(
        id="disk",
        provider=Provider.AZURE,
        account_id="1",
        region="eastus",
        resource_type=ResourceType.DISK,
        name="tiny",
        attached=False,
        estimated_monthly_cost=0.5,
    )
    assert evaluate(disk, settings) is None
