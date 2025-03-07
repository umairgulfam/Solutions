import pytest

from garbage_collector.config import Settings
from garbage_collector.service import GarbageCollectorService
from garbage_collector.store import Store


@pytest.fixture
def settings(tmp_path):
    return Settings(database_url=f"sqlite:///{tmp_path / 'test.db'}", api_key="test-key")


@pytest.fixture
def service(settings):
    return GarbageCollectorService(settings, Store(settings.database_url))
