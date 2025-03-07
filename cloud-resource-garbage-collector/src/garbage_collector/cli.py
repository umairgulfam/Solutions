import csv
import json
from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console
from rich.table import Table

from garbage_collector.config import get_settings
from garbage_collector.models import FindingStatus, Provider
from garbage_collector.service import GarbageCollectorService
from garbage_collector.store import Store

app = typer.Typer(help="Find and govern unused cloud resources safely.")
console = Console()


def _service() -> GarbageCollectorService:
    settings = get_settings()
    return GarbageCollectorService(settings, Store(settings.database_url))


def _print_table(findings: list) -> None:
    table = Table(title="Cloud waste findings")
    for column in ("ID", "Provider", "Resource", "Reason", "Owner", "USD/month", "Status"):
        table.add_column(column)
    for finding in findings:
        table.add_row(
            finding.fingerprint,
            finding.resource.provider,
            finding.resource.name,
            finding.reason,
            finding.resource.owner,
            f"${finding.estimated_monthly_savings:,.2f}",
            finding.status,
        )
    console.print(table)
    console.print(
        f"Potential monthly savings: ${sum(f.estimated_monthly_savings for f in findings):,.2f}"
    )


@app.command()
def scan(
    provider: Annotated[list[Provider] | None, typer.Option()] = None,
    output: Annotated[str, typer.Option()] = "table",
    file: Annotated[Path | None, typer.Option()] = None,
) -> None:
    """Run a read-only inventory scan."""
    findings = _service().scan(provider or [Provider.MOCK])
    if output == "table":
        _print_table(findings)
    elif output == "json":
        content = json.dumps([f.model_dump(mode="json") for f in findings], indent=2)
        file.write_text(content, encoding="utf-8") if file else console.print(content)
    elif output == "csv":
        if file is None:
            raise typer.BadParameter("--file is required for CSV output")
        with file.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(
                [
                    "fingerprint",
                    "provider",
                    "resource",
                    "type",
                    "reason",
                    "owner",
                    "monthly_savings",
                    "status",
                ]
            )
            for f in findings:
                writer.writerow(
                    [
                        f.fingerprint,
                        f.resource.provider,
                        f.resource.name,
                        f.resource.resource_type,
                        f.reason,
                        f.resource.owner,
                        f.estimated_monthly_savings,
                        f.status,
                    ]
                )
    else:
        raise typer.BadParameter("output must be table, json, or csv")


@app.command("list")
def list_findings() -> None:
    _print_table(_service().store.list())


@app.command()
def decide(fingerprint: str, decision: FindingStatus, actor: str, comment: str = "") -> None:
    """Approve, reject, or ignore a finding."""
    if decision not in {FindingStatus.APPROVED, FindingStatus.REJECTED, FindingStatus.IGNORED}:
        raise typer.BadParameter("decision must be approved, rejected, or ignored")
    finding = _service().decide(fingerprint, decision, actor, comment)
    console.print(f"{finding.fingerprint}: {finding.status}")


@app.command()
def delete(fingerprint: str, actor: str, confirm: bool = typer.Option(False, "--confirm")) -> None:
    """Execute an already-approved deletion when deletion is enabled."""
    if not confirm:
        raise typer.BadParameter("Pass --confirm after reviewing the approved finding")
    finding = _service().delete(fingerprint, actor)
    console.print(f"{finding.fingerprint}: {finding.status}")


@app.command("seed-demo")
def seed_demo() -> None:
    findings = _service().scan([Provider.MOCK])
    console.print(f"Seeded {len(findings)} deterministic demo findings")


if __name__ == "__main__":
    app()
