"""Azure Cost Management source.

Requires ``azure-identity`` and ``azure-mgmt-costmanagement``
(``pip install 'costdetective[azure]'``). Authentication uses
``DefaultAzureCredential``, so a managed identity, workload identity, service
principal env vars or ``az login`` all work without code changes.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta

from costdetective.models import CostSnapshot, ServiceCost
from costdetective.servicemap import default_map
from costdetective.sources.base import CostSource, SourceError


class AzureCostSource(CostSource):
    name = "azure"

    def _scope(self) -> str:
        scope = self.config.get("azure.scope")
        if scope:
            return scope
        subscription = self.config.get("azure.subscription_id")
        if not subscription:
            raise SourceError(
                "azure.subscription_id (or azure.scope) must be set to query Azure costs"
            )
        return f"/subscriptions/{subscription}"

    def _client(self):  # pragma: no cover - requires network/credentials
        try:
            from azure.identity import DefaultAzureCredential
            from azure.mgmt.costmanagement import CostManagementClient
        except ImportError as exc:
            raise SourceError(
                "Azure SDK not installed. Install it with: "
                "pip install 'costdetective[azure]'"
            ) from exc
        return CostManagementClient(DefaultAzureCredential())

    def fetch(self, days: int = 1) -> CostSnapshot:  # pragma: no cover - network
        client = self._client()
        today = date.today()
        period_start = today - timedelta(days=days)
        baseline_start = today - timedelta(days=days * 2)

        query = {
            "type": "ActualCost",
            "timeframe": "Custom",
            "time_period": {
                "from_property": datetime.combine(baseline_start, datetime.min.time()),
                "to": datetime.combine(today, datetime.min.time()),
            },
            "dataset": {
                "granularity": "Daily",
                "aggregation": {"total": {"name": "Cost", "function": "Sum"}},
                "grouping": [{"type": "Dimension", "name": "ServiceName"}],
            },
        }

        result = client.query.usage(scope=self._scope(), parameters=query)
        columns = [c.name for c in result.columns]
        idx = {name: i for i, name in enumerate(columns)}

        smap = default_map()
        current: dict[str, float] = {}
        previous: dict[str, float] = {}
        currency = self.config.get("currency", "USD")

        for row in result.rows or []:
            cost = float(row[idx.get("Cost", 0)])
            raw_date = str(row[idx["UsageDate"]]) if "UsageDate" in idx else ""
            row_date = _parse_azure_date(raw_date, today)
            service = smap.normalise(str(row[idx.get("ServiceName", 1)]))
            if "Currency" in idx:
                currency = str(row[idx["Currency"]])
            target = current if row_date >= period_start else previous
            target[service] = target.get(service, 0.0) + cost

        services = [
            ServiceCost(
                service=name,
                current=current.get(name, 0.0),
                previous=previous.get(name, 0.0),
                provider="azure",
                account=self.config.get("azure.subscription_id"),
            )
            for name in sorted(set(current) | set(previous))
        ]

        return CostSnapshot(
            period_start=period_start,
            period_end=today,
            baseline_start=baseline_start,
            baseline_end=period_start,
            currency=currency,
            services=services,
            source="azure",
        )


def _parse_azure_date(raw: str, fallback: date) -> date:
    """Azure returns usage dates as ``20260903`` ints or ISO strings."""
    raw = raw.strip()
    if not raw:
        return fallback
    if raw.isdigit() and len(raw) == 8:
        return date(int(raw[0:4]), int(raw[4:6]), int(raw[6:8]))
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).date()
    except ValueError:
        return fallback
