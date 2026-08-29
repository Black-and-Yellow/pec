from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal
from typing import Any
from uuid import uuid4

from sqlalchemy import (
    JSON,
    Boolean,
    DateTime,
    ForeignKey,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def utc_now() -> datetime:
    return datetime.now(UTC)


def new_id() -> str:
    return str(uuid4())


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(64), primary_key=True, default=new_id)
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    display_name: Mapped[str] = mapped_column(String(100))
    password_hash: Mapped[str | None] = mapped_column(String(255))
    google_subject: Mapped[str | None] = mapped_column(String(255), unique=True, index=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )

    refresh_sessions: Mapped[list[RefreshSession]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class RefreshSession(Base):
    __tablename__ = "refresh_sessions"

    id: Mapped[str] = mapped_column(String(64), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    user: Mapped[User] = relationship(back_populates="refresh_sessions")


class Transaction(Base):
    __tablename__ = "transactions"

    id: Mapped[str] = mapped_column(String(64), primary_key=True, default=new_id)
    device_id: Mapped[str] = mapped_column(String(128), index=True)
    vpa: Mapped[str] = mapped_column(String(193), index=True)
    payee_name: Mapped[str | None] = mapped_column(String(128))
    amount: Mapped[Decimal | None] = mapped_column(Numeric(12, 2))
    transaction_note: Mapped[str | None] = mapped_column(String(250))
    currency: Mapped[str] = mapped_column(String(3), default="INR")
    transaction_reference: Mapped[str | None] = mapped_column(String(100))
    status: Mapped[str] = mapped_column(String(24), index=True)
    source: Mapped[str] = mapped_column(String(32))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    assessment: Mapped[RiskAssessment | None] = relationship(
        back_populates="transaction", cascade="all, delete-orphan", uselist=False
    )


class RiskAssessment(Base):
    __tablename__ = "risk_assessments"

    id: Mapped[str] = mapped_column(String(64), primary_key=True, default=new_id)
    transaction_id: Mapped[str] = mapped_column(
        ForeignKey("transactions.id", ondelete="CASCADE"), unique=True, index=True
    )
    score: Mapped[int] = mapped_column(Integer)
    level: Mapped[str] = mapped_column(String(16), index=True)
    recommended_action: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    # Set the first time a user prepares an incident report from this
    # assessment. It exists so a repeated "prepare report" tap cannot count
    # as a second complaint against the payee.
    reported_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    transaction: Mapped[Transaction] = relationship(back_populates="assessment")
    signals: Mapped[list[RiskSignalRecord]] = relationship(
        back_populates="assessment",
        cascade="all, delete-orphan",
        order_by="RiskSignalRecord.position",
    )


class RiskSignalRecord(Base):
    __tablename__ = "risk_signals"
    __table_args__ = (UniqueConstraint("assessment_id", "position"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    assessment_id: Mapped[str] = mapped_column(
        ForeignKey("risk_assessments.id", ondelete="CASCADE"), index=True
    )
    position: Mapped[int] = mapped_column(Integer)
    code: Mapped[str] = mapped_column(String(64))
    label: Mapped[str] = mapped_column(String(160))
    weight: Mapped[int] = mapped_column(Integer)
    evidence: Mapped[str] = mapped_column(String(300))

    assessment: Mapped[RiskAssessment] = relationship(back_populates="signals")


class PayeeReputation(Base):
    """Aggregate standing of one VPA across every device FinGuard serves.

    This is FinGuard's own bureau ledger, and it is the honest answer to
    "why not just read the payee's UPI history?" — NPCI does not expose one.
    A credit bureau is not a regulator either: CIBIL holds what its member
    banks contribute. This table holds what the FinGuard network observes.

    It deliberately outlives the assessment records in ``transactions``,
    which are pruned for privacy. Nothing here identifies a payer: only
    counters, and the salted device digests in :class:`PayeeDeviceObservation`.
    """

    __tablename__ = "payee_reputation"

    vpa: Mapped[str] = mapped_column(String(193), primary_key=True)
    first_seen_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, index=True
    )
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    check_count: Mapped[int] = mapped_column(Integer, default=0)
    distinct_device_count: Mapped[int] = mapped_column(Integer, default=0)
    safe_count: Mapped[int] = mapped_column(Integer, default=0)
    caution_count: Mapped[int] = mapped_column(Integer, default=0)
    high_count: Mapped[int] = mapped_column(Integer, default=0)
    reported_count: Mapped[int] = mapped_column(Integer, default=0)
    recent_new_device_count: Mapped[int] = mapped_column(Integer, default=0)
    recent_window_started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now
    )


class PayeeDeviceObservation(Base):
    """One (payee, device) pair, so distinct reach cannot be inflated by repeats.

    The device value stored here is the same salted digest the transaction
    ledger uses, never a raw client identifier.
    """

    __tablename__ = "payee_device_observations"
    __table_args__ = (UniqueConstraint("vpa", "device_key"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    vpa: Mapped[str] = mapped_column(String(193), index=True)
    device_key: Mapped[str] = mapped_column(String(128), index=True)
    first_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class FraudIndicator(Base):
    __tablename__ = "fraud_indicators"
    __table_args__ = (UniqueConstraint("indicator_type", "normalized_value"),)

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    indicator_type: Mapped[str] = mapped_column(String(32), index=True)
    normalized_value: Mapped[str] = mapped_column(String(255), index=True)
    label: Mapped[str] = mapped_column(String(160))
    report_count: Mapped[int] = mapped_column(Integer, default=0)
    relationships: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    source: Mapped[str] = mapped_column(String(40), default="SEEDED_DEMO_DATA")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
