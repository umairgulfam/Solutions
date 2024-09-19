"""Work out who owns a cost movement.

Resolution order, first hit wins:
  1. tags on the billed resource      (Owner / Team / CostCenter)
  2. tags on the suspected change     (terraform resource tags)
  3. ``ownership.by_service`` in config
  4. ``ownership.by_path``  — matched against files touched by the commit
  5. ``ownership.by_author`` — commit author to team
  6. the commit author themselves
  7. ``ownership.default``
"""

from __future__ import annotations

from dataclasses import dataclass

from costdetective.config import Config
from costdetective.models import ServiceCost, Suspect


@dataclass
class Ownership:
    owner: str
    source: str


class OwnershipResolver:
    def __init__(self, config: Config) -> None:
        self.tag_keys: list[str] = list(config.get("ownership.tag_keys", []))
        self.by_service: dict[str, str] = dict(config.get("ownership.by_service", {}))
        self.by_author: dict[str, str] = dict(config.get("ownership.by_author", {}))
        self.by_path: dict[str, str] = dict(config.get("ownership.by_path", {}))
        self.default: str = config.get("ownership.default", "unassigned")

    def resolve(self, service: ServiceCost, suspects: list[Suspect]) -> Ownership:
        top = suspects[0].change if suspects else None

        for key in self.tag_keys:
            if value := service.tags.get(key):
                return Ownership(value, f"tag:{key}")

        if top is not None:
            if top.team:
                return Ownership(top.team, f"{top.source}:team")
            tags = top.metadata.get("tags") or {}
            for key in self.tag_keys:
                if value := tags.get(key):
                    return Ownership(str(value), f"{top.source}:tag:{key}")

        for name, owner in self.by_service.items():
            if name.lower() == service.service.lower():
                return Ownership(owner, "config:by_service")

        if top is not None:
            files = top.metadata.get("files") or []
            for prefix, owner in self.by_path.items():
                if any(str(f).startswith(prefix) for f in files):
                    return Ownership(owner, "config:by_path")
            if top.author:
                if mapped_team := self.by_author.get(top.author):
                    return Ownership(mapped_team, "config:by_author")
                return Ownership(top.author, f"{top.source}:author")

        return Ownership(self.default, "default")
