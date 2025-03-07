from abc import ABC, abstractmethod

from garbage_collector.models import CloudResource, Provider


class CloudProvider(ABC):
    name: Provider

    @abstractmethod
    def inventory(self) -> list[CloudResource]:
        """Return a normalized, read-only cloud inventory."""

    def delete(self, resource: CloudResource) -> str:
        """Delete a resource. Providers must override this explicitly."""
        raise NotImplementedError(f"Deletion is not implemented for {self.name}")
