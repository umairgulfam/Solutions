"""Configuration loading.

Config resolution order (last wins):
  1. built-in defaults
  2. YAML file (``--config``, ``./costdetective.yaml``, ``~/.costdetective.yaml``)
  3. environment variables (``COSTDETECTIVE_*``)
  4. CLI flags

``${VAR}`` and ``${VAR:-fallback}`` inside the YAML are expanded from the
environment so secrets never have to live in the file.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

DEFAULT_CONFIG_NAMES = ("costdetective.yaml", "costdetective.yml", ".costdetective.yaml")

_ENV_PATTERN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")


class ConfigError(ValueError):
    """Raised when the configuration file is unusable."""


def _expand(value: Any) -> Any:
    """Recursively expand ``${VAR}`` / ``${VAR:-default}`` in strings."""
    if isinstance(value, str):

        def repl(match: re.Match[str]) -> str:
            name, fallback = match.group(1), match.group(2)
            return os.environ.get(name, fallback if fallback is not None else "")

        return _ENV_PATTERN.sub(repl, value)
    if isinstance(value, dict):
        return {k: _expand(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_expand(v) for v in value]
    return value


def _deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


DEFAULTS: dict[str, Any] = {
    "cost_source": "demo",
    "change_sources": ["terraform", "git"],
    "currency": "USD",
    "lookback_days": 1,
    "correlation_window_hours": 72,
    "min_delta": 1.0,
    "aws": {
        "profile": None,
        "region": "us-east-1",
        "granularity": "DAILY",
        "metric": "UnblendedCost",
        "group_by": "SERVICE",
    },
    "azure": {
        "subscription_id": None,
        "scope": None,
    },
    "terraform": {
        "plan_json": None,
        "state_json": None,
        "workdir": ".",
    },
    "git": {
        "repo": ".",
        "branch": None,
        "max_commits": 200,
    },
    "ownership": {
        "tag_keys": ["Owner", "owner", "Team", "team", "CostCenter"],
        "by_service": {},
        "by_author": {},
        "by_path": {},
        "default": "unassigned",
    },
    "notify": {
        "slack_webhook": None,
        "mention_on_threshold": None,
    },
    "thresholds": {
        "warn": 25.0,
        "fail": 100.0,
    },
}


@dataclass
class Config:
    """Validated, merged configuration."""

    data: dict[str, Any] = field(default_factory=lambda: dict(DEFAULTS))
    path: Path | None = None

    def get(self, dotted: str, default: Any = None) -> Any:
        """Fetch a nested key: ``cfg.get("aws.region")``."""
        node: Any = self.data
        for part in dotted.split("."):
            if not isinstance(node, dict) or part not in node:
                return default
            node = node[part]
        return node if node is not None else default

    def __getitem__(self, key: str) -> Any:
        return self.data[key]

    def validate(self) -> list[str]:
        """Return a list of human-readable problems (empty means valid)."""
        problems: list[str] = []
        source = self.get("cost_source")
        if source not in {"demo", "aws", "azure", "file"}:
            problems.append(
                f"cost_source '{source}' is not one of: demo, aws, azure, file"
            )
        if source == "azure" and not self.get("azure.subscription_id"):
            problems.append("cost_source is 'azure' but azure.subscription_id is unset")
        for name in self.get("change_sources", []):
            if name not in {"terraform", "git", "demo"}:
                problems.append(f"unknown change source '{name}'")
        if self.get("min_delta", 0) < 0:
            problems.append("min_delta must be >= 0")
        warn, fail = self.get("thresholds.warn"), self.get("thresholds.fail")
        if warn is not None and fail is not None and warn > fail:
            problems.append("thresholds.warn should be <= thresholds.fail")
        return problems


def _env_overrides() -> dict[str, Any]:
    """Map COSTDETECTIVE_* env vars onto config keys."""
    mapping = {
        "COSTDETECTIVE_COST_SOURCE": ("cost_source",),
        "COSTDETECTIVE_AWS_PROFILE": ("aws", "profile"),
        "COSTDETECTIVE_AWS_REGION": ("aws", "region"),
        "COSTDETECTIVE_AZURE_SUBSCRIPTION_ID": ("azure", "subscription_id"),
        "COSTDETECTIVE_TERRAFORM_PLAN": ("terraform", "plan_json"),
        "COSTDETECTIVE_TERRAFORM_STATE": ("terraform", "state_json"),
        "COSTDETECTIVE_TERRAFORM_WORKDIR": ("terraform", "workdir"),
        "COSTDETECTIVE_GIT_REPO": ("git", "repo"),
        "COSTDETECTIVE_SLACK_WEBHOOK": ("notify", "slack_webhook"),
    }
    out: dict[str, Any] = {}
    for env_key, path in mapping.items():
        value = os.environ.get(env_key)
        if value in (None, ""):
            continue
        node = out
        for part in path[:-1]:
            node = node.setdefault(part, {})
        node[path[-1]] = value
    return out


def find_config_file(explicit: str | os.PathLike[str] | None = None) -> Path | None:
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_file():
            raise ConfigError(f"config file not found: {path}")
        return path
    for name in DEFAULT_CONFIG_NAMES:
        candidate = Path.cwd() / name
        if candidate.is_file():
            return candidate
    home = Path.home() / ".costdetective.yaml"
    return home if home.is_file() else None


def load_config(explicit: str | os.PathLike[str] | None = None) -> Config:
    """Load and merge configuration from file + environment."""
    path = find_config_file(explicit)
    data = dict(DEFAULTS)

    if path is not None:
        try:
            raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as exc:  # pragma: no cover - depends on bad input
            raise ConfigError(f"could not parse {path}: {exc}") from exc
        if not isinstance(raw, dict):
            raise ConfigError(f"{path} must contain a YAML mapping at the top level")
        data = _deep_merge(data, _expand(raw))

    data = _deep_merge(data, _env_overrides())
    return Config(data=data, path=path)
