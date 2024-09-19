"""Resolve infrastructure resource types and free text onto billable services."""

from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
from importlib import resources
from typing import Any

import yaml


@dataclass
class ServiceMap:
    resource_types: dict[str, str]
    keywords: dict[str, list[str]]
    actions: dict[str, str]
    actions_by_change: dict[str, str]

    @classmethod
    def load(cls, overrides: dict[str, Any] | None = None) -> ServiceMap:
        raw = yaml.safe_load(
            resources.files("costdetective.data")
            .joinpath("service_map.yaml")
            .read_text(encoding="utf-8")
        )
        data: dict[str, Any] = {
            "resource_types": dict(raw.get("resource_types", {})),
            "keywords": {k: list(v) for k, v in raw.get("keywords", {}).items()},
            "actions": dict(raw.get("actions", {})),
            "actions_by_change": dict(raw.get("actions_by_change", {})),
        }
        for key, value in (overrides or {}).items():
            if key in data and isinstance(value, dict):
                data[key].update(value)
        return cls(**data)  # type: ignore[arg-type]

    # -- resolution --------------------------------------------------------

    def service_for_resource_type(self, resource_type: str) -> str | None:
        return self.resource_types.get(resource_type.strip())

    def services_in_text(self, text: str) -> list[str]:
        """Best-effort keyword match of a commit message or resource name."""
        haystack = (text or "").lower()
        hits: list[str] = []
        for service, words in self.keywords.items():
            if any(word in haystack for word in words):
                hits.append(service)
        return hits

    def normalise(self, service: str) -> str:
        """Fold provider-specific billing labels onto our canonical names."""
        return _canonical(service)

    def action_for(self, service: str, change_action: str | None = None, resource: str = "the resource") -> str:
        template = self.actions.get(service)
        if template is None and change_action:
            template = self.actions_by_change.get(change_action)
        if template is None:
            template = self.actions.get("default", "Review recent changes.")
        return template.format(service=service, resource=resource)


# Cloud bills label the same product a dozen ways. Fold the common ones.
_ALIASES = {
    "amazon elastic compute cloud - compute": "EC2",
    "amazon elastic compute cloud": "EC2",
    "ec2 - other": "EC2",
    "amazon relational database service": "RDS",
    "amazon api gateway": "API Gateway",
    "aws lambda": "Lambda",
    "amazon simple storage service": "S3",
    "amazon cloudfront": "CloudFront",
    "amazon elastic kubernetes service": "EKS",
    "amazon cloudwatch": "CloudWatch",
    "amazoncloudwatch": "CloudWatch",
    "amazon virtual private cloud": "VPC",
    "amazon sagemaker": "SageMaker",
    "amazon bedrock": "Bedrock",
    "azure openai": "AI Foundry",
    "cognitive services": "AI Foundry",
    "azure ai foundry": "AI Foundry",
    "azure ai services": "AI Foundry",
    "virtual machines": "Virtual Machines",
}


def _canonical(service: str) -> str:
    key = (service or "").strip().lower()
    return _ALIASES.get(key, service.strip())


@lru_cache(maxsize=1)
def default_map() -> ServiceMap:
    return ServiceMap.load()
