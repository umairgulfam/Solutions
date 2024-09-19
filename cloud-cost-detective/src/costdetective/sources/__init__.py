"""Source registry.

Register a new provider by adding it to ``COST_SOURCES`` or ``CHANGE_SOURCES``.
"""

from __future__ import annotations

from costdetective.config import Config
from costdetective.sources.base import ChangeSource, CostSource, SourceError

__all__ = [
    "ChangeSource",
    "CostSource",
    "SourceError",
    "build_change_sources",
    "build_cost_source",
    "list_sources",
]


def _cost_registry() -> dict[str, type[CostSource]]:
    from costdetective.sources.aws import AwsCostSource
    from costdetective.sources.azure import AzureCostSource
    from costdetective.sources.demo import DemoCostSource

    return {
        "demo": DemoCostSource,
        "file": DemoCostSource,  # a user-supplied fixture via demo.fixture
        "aws": AwsCostSource,
        "azure": AzureCostSource,
    }


def _change_registry() -> dict[str, type[ChangeSource]]:
    from costdetective.sources.demo import DemoChangeSource
    from costdetective.sources.git import GitChangeSource
    from costdetective.sources.terraform import TerraformChangeSource

    return {
        "demo": DemoChangeSource,
        "terraform": TerraformChangeSource,
        "git": GitChangeSource,
    }


def build_cost_source(config: Config, name: str | None = None) -> CostSource:
    key = (name or config.get("cost_source", "demo")).lower()
    registry = _cost_registry()
    if key not in registry:
        raise SourceError(
            f"unknown cost source '{key}'. Available: {', '.join(sorted(registry))}"
        )
    return registry[key](config)


def build_change_sources(config: Config, names: list[str] | None = None) -> list[ChangeSource]:
    keys = names if names is not None else config.get("change_sources", [])
    registry = _change_registry()
    sources: list[ChangeSource] = []
    for key in keys:
        key = key.lower()
        if key not in registry:
            raise SourceError(
                f"unknown change source '{key}'. Available: {', '.join(sorted(registry))}"
            )
        sources.append(registry[key](config))
    return sources


def list_sources() -> dict[str, list[str]]:
    return {
        "cost": sorted(_cost_registry()),
        "change": sorted(_change_registry()),
    }
