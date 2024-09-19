"""Terraform change source.

Reads a machine-readable plan or state:

    terraform show -json tfplan   > plan.json
    terraform show -json          > state.json

A plan tells us what is *about* to change (great for pre-merge cost gating);
a state tells us what *did* change, using each resource's creation timestamp
where the provider records one.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from costdetective.models import Change
from costdetective.servicemap import default_map
from costdetective.sources.base import ChangeSource, SourceError

_ACTION_PRIORITY = ("create", "update", "delete")


class TerraformChangeSource(ChangeSource):
    name = "terraform"

    def check(self) -> None:
        configured = self.config.get("terraform.plan_json") or self.config.get(
            "terraform.state_json"
        )
        if not configured and shutil.which("terraform") is None:
            raise SourceError(
                "no terraform.plan_json/state_json configured and the "
                "`terraform` binary is not on PATH"
            )

    def _load_document(self) -> dict[str, Any]:
        for key in ("terraform.plan_json", "terraform.state_json"):
            path = self.config.get(key)
            if path:
                file = Path(path).expanduser()
                if not file.is_file():
                    raise SourceError(f"{key} points at a missing file: {file}")
                return json.loads(file.read_text(encoding="utf-8"))
        return self._shell_out()

    def _shell_out(self) -> dict[str, Any]:  # pragma: no cover - needs terraform
        workdir = self.config.get("terraform.workdir", ".")
        if shutil.which("terraform") is None:
            raise SourceError("`terraform` binary not found on PATH")
        try:
            proc = subprocess.run(
                ["terraform", "show", "-json"],
                cwd=workdir,
                capture_output=True,
                text=True,
                timeout=120,
                check=True,
            )
        except subprocess.CalledProcessError as exc:
            raise SourceError(f"terraform show failed: {exc.stderr.strip()}") from exc
        except subprocess.TimeoutExpired as exc:
            raise SourceError("terraform show timed out after 120s") from exc
        return json.loads(proc.stdout or "{}")

    def fetch(self, since: datetime) -> list[Change]:
        document = self._load_document()
        smap = default_map()
        changes: list[Change] = []

        # ---- plan format: resource_changes[] ------------------------------
        for entry in document.get("resource_changes", []) or []:
            actions = [a for a in entry.get("change", {}).get("actions", []) if a != "no-op"]
            if not actions:
                continue
            action = next((a for a in _ACTION_PRIORITY if a in actions), actions[0])
            resource_type = entry.get("type", "")
            address = entry.get("address", resource_type)
            after = entry.get("change", {}).get("after") or {}
            tags = _extract_tags(after)
            service = smap.service_for_resource_type(resource_type)
            changes.append(
                Change(
                    source="terraform",
                    identifier=address,
                    title=_describe(action, resource_type, address, entry),
                    timestamp=_timestamp_for(after, since),
                    action=action,
                    author=tags.get("Owner") or tags.get("owner"),
                    team=tags.get("Team") or tags.get("team"),
                    resource_types=[resource_type] if resource_type else [],
                    services=[service] if service else [],
                    metadata={"address": address, "tags": tags, "planned": True},
                )
            )

        # ---- state format: values.root_module.resources[] ------------------
        if not changes:
            for resource in _walk_state(document.get("values", {}).get("root_module", {})):
                resource_type = resource.get("type", "")
                address = resource.get("address", resource_type)
                values = resource.get("values") or {}
                created = _timestamp_for(values, since)
                if created < since:
                    continue
                tags = _extract_tags(values)
                service = smap.service_for_resource_type(resource_type)
                changes.append(
                    Change(
                        source="terraform",
                        identifier=address,
                        title=f"{_pretty(resource_type)} resource created ({address})",
                        timestamp=created,
                        action="create",
                        author=tags.get("Owner") or tags.get("owner"),
                        team=tags.get("Team") or tags.get("team"),
                        resource_types=[resource_type] if resource_type else [],
                        services=[service] if service else [],
                        metadata={"address": address, "tags": tags},
                    )
                )

        return [c for c in changes if c.timestamp >= since]


def _walk_state(module: dict[str, Any]) -> list[dict[str, Any]]:
    resources = list(module.get("resources", []) or [])
    for child in module.get("child_modules", []) or []:
        resources.extend(_walk_state(child))
    return resources


def _extract_tags(values: dict[str, Any]) -> dict[str, str]:
    for key in ("tags", "tags_all", "labels"):
        tags = values.get(key)
        if isinstance(tags, dict):
            return {str(k): str(v) for k, v in tags.items()}
    return {}


def _timestamp_for(values: dict[str, Any], since: datetime) -> datetime:
    """Use a provider-recorded creation time when available."""
    for key in ("created_at", "creation_date", "create_time", "created_time"):
        raw = values.get(key)
        if isinstance(raw, str):
            try:
                return datetime.fromisoformat(raw.replace("Z", "+00:00")).replace(tzinfo=None)
            except ValueError:
                continue
    # Planned changes have no timestamp; treat them as imminent.
    return max(since, datetime.utcnow() - timedelta(minutes=5))


def _pretty(resource_type: str) -> str:
    smap = default_map()
    return smap.service_for_resource_type(resource_type) or resource_type


def _describe(action: str, resource_type: str, address: str, entry: dict[str, Any]) -> str:
    label = _pretty(resource_type)
    verbs = {"create": "created", "update": "updated", "delete": "destroyed"}
    verb = verbs.get(action, "changed")
    short = address.split(".")[-1]
    return f"{label} resource {verb} ({short})"
