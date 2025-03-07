import builtins
from datetime import UTC, datetime

from sqlalchemy import DateTime, String, Text, create_engine, select
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column

from garbage_collector.models import Finding, FindingStatus


class Base(DeclarativeBase):
    pass


class FindingRecord(Base):
    __tablename__ = "findings"
    fingerprint: Mapped[str] = mapped_column(String(20), primary_key=True)
    payload: Mapped[str] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(20), default=FindingStatus.PENDING)
    actor: Mapped[str | None] = mapped_column(String(100), nullable=True)
    comment: Mapped[str | None] = mapped_column(Text, nullable=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class AuditEvent(Base):
    __tablename__ = "audit_events"
    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    fingerprint: Mapped[str] = mapped_column(String(20), index=True)
    action: Mapped[str] = mapped_column(String(30))
    actor: Mapped[str] = mapped_column(String(100))
    comment: Mapped[str] = mapped_column(Text, default="")
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class Store:
    def __init__(self, database_url: str) -> None:
        kwargs = {"check_same_thread": False} if database_url.startswith("sqlite") else {}
        self.engine = create_engine(database_url, connect_args=kwargs)
        Base.metadata.create_all(self.engine)

    def upsert(self, findings: list[Finding]) -> None:
        with Session(self.engine) as session:
            for finding in findings:
                record = session.get(FindingRecord, finding.fingerprint)
                if record is None:
                    record = FindingRecord(
                        fingerprint=finding.fingerprint,
                        payload=finding.model_dump_json(),
                        status=finding.status,
                        updated_at=datetime.now(UTC),
                    )
                    session.add(record)
                else:
                    finding.status = FindingStatus(record.status)
                    record.payload = finding.model_dump_json()
                    record.updated_at = datetime.now(UTC)
            session.commit()

    def list(self) -> list[Finding]:
        with Session(self.engine) as session:
            records = session.scalars(
                select(FindingRecord).order_by(FindingRecord.updated_at.desc())
            ).all()
            result = []
            for record in records:
                finding = Finding.model_validate_json(record.payload)
                finding.status = FindingStatus(record.status)
                result.append(finding)
            return result

    def get(self, fingerprint: str) -> Finding | None:
        with Session(self.engine) as session:
            record = session.get(FindingRecord, fingerprint)
            if record is None:
                return None
            finding = Finding.model_validate_json(record.payload)
            finding.status = FindingStatus(record.status)
            return finding

    def transition(
        self, fingerprint: str, status: FindingStatus, actor: str, comment: str = ""
    ) -> Finding:
        with Session(self.engine) as session:
            record = session.get(FindingRecord, fingerprint)
            if record is None:
                raise KeyError(fingerprint)
            record.status = status
            record.actor = actor
            record.comment = comment
            record.updated_at = datetime.now(UTC)
            session.add(
                AuditEvent(
                    fingerprint=fingerprint,
                    action=status,
                    actor=actor,
                    comment=comment,
                    occurred_at=datetime.now(UTC),
                )
            )
            session.commit()
            finding = Finding.model_validate_json(record.payload)
            finding.status = status
            return finding

    def audit(self, fingerprint: str | None = None) -> builtins.list[dict[str, str]]:
        with Session(self.engine) as session:
            stmt = select(AuditEvent).order_by(AuditEvent.occurred_at.desc())
            if fingerprint:
                stmt = stmt.where(AuditEvent.fingerprint == fingerprint)
            return [
                {
                    "fingerprint": e.fingerprint,
                    "action": e.action,
                    "actor": e.actor,
                    "comment": e.comment,
                    "occurred_at": e.occurred_at.isoformat(),
                }
                for e in session.scalars(stmt).all()
            ]
