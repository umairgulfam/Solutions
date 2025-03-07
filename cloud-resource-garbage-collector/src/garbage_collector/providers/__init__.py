from garbage_collector.models import Provider
from garbage_collector.providers.aws import AWSProvider
from garbage_collector.providers.azure import AzureProvider
from garbage_collector.providers.base import CloudProvider
from garbage_collector.providers.gcp import GCPProvider
from garbage_collector.providers.mock import MockProvider


def get_provider(provider: Provider) -> CloudProvider:
    providers: dict[Provider, type[CloudProvider]] = {
        Provider.AWS: AWSProvider,
        Provider.AZURE: AzureProvider,
        Provider.GCP: GCPProvider,
        Provider.MOCK: MockProvider,
    }
    return providers[provider]()


__all__ = ["CloudProvider", "get_provider"]
