"""AWS Cost Explorer source.

Requires ``boto3`` (``pip install 'costdetective[aws]'``) and an identity with
``ce:GetCostAndUsage``. Cost Explorer bills per API call, so we make exactly one
request covering both the period and its baseline.
"""

from __future__ import annotations

from datetime import date, timedelta

from costdetective.models import CostSnapshot, ServiceCost
from costdetective.servicemap import default_map
from costdetective.sources.base import CostSource, SourceError


class AwsCostSource(CostSource):
    name = "aws"

    def _client(self):  # pragma: no cover - requires network/credentials
        try:
            import boto3
        except ImportError as exc:
            raise SourceError(
                "boto3 is not installed. Install it with: pip install 'costdetective[aws]'"
            ) from exc
        profile = self.config.get("aws.profile")
        region = self.config.get("aws.region", "us-east-1")
        session = (
            boto3.Session(profile_name=profile, region_name=region)
            if profile
            else boto3.Session(region_name=region)
        )
        return session.client("ce")

    def check(self) -> None:  # pragma: no cover - requires credentials
        self._client().get_cost_and_usage(
            TimePeriod={
                "Start": (date.today() - timedelta(days=2)).isoformat(),
                "End": date.today().isoformat(),
            },
            Granularity="DAILY",
            Metrics=[self.config.get("aws.metric", "UnblendedCost")],
        )

    def fetch(self, days: int = 1) -> CostSnapshot:  # pragma: no cover - network
        client = self._client()
        metric = self.config.get("aws.metric", "UnblendedCost")
        group_by = self.config.get("aws.group_by", "SERVICE")

        today = date.today()
        period_start = today - timedelta(days=days)
        baseline_start = today - timedelta(days=days * 2)

        response = client.get_cost_and_usage(
            TimePeriod={"Start": baseline_start.isoformat(), "End": today.isoformat()},
            Granularity="DAILY",
            Metrics=[metric],
            GroupBy=[{"Type": "DIMENSION", "Key": group_by}],
        )

        smap = default_map()
        current: dict[str, float] = {}
        previous: dict[str, float] = {}
        currency = self.config.get("currency", "USD")

        for bucket in response.get("ResultsByTime", []):
            bucket_start = date.fromisoformat(bucket["TimePeriod"]["Start"])
            target = current if bucket_start >= period_start else previous
            for group in bucket.get("Groups", []):
                raw_service = group["Keys"][0]
                service = smap.normalise(raw_service)
                amount_obj = group["Metrics"][metric]
                currency = amount_obj.get("Unit", currency)
                target[service] = target.get(service, 0.0) + float(amount_obj["Amount"])

        services = [
            ServiceCost(
                service=name,
                current=current.get(name, 0.0),
                previous=previous.get(name, 0.0),
                provider="aws",
                account=self.config.get("aws.account_id"),
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
            source="aws",
        )
