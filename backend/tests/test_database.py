from __future__ import annotations

from datetime import UTC, datetime, timedelta
from decimal import Decimal

from sqlalchemy import func, select

from app.db.database import Database
from app.db.models import (
    FraudIndicator,
    RefreshSession,
    RiskAssessment,
    RiskSignalRecord,
    Transaction,
    User,
)
from app.db.seed import seed_demo_data
from app.repositories.indicator_repository import IndicatorRepository
from app.repositories.transaction_repository import TransactionRepository
from app.repositories.user_repository import UserRepository


def test_sqlite_pragmas_and_demo_seed_are_stable_across_restarts() -> None:
    database = Database("sqlite://")
    try:
        database.create_schema()
        with database.engine.connect() as connection:
            assert connection.exec_driver_sql("PRAGMA foreign_keys").scalar_one() == 1
            assert connection.exec_driver_sql("PRAGMA busy_timeout").scalar_one() == 5_000

        with database.session() as session:
            seed_demo_data(session)
            transaction_count = session.scalar(select(func.count()).select_from(Transaction))
            indicator_count = session.scalar(select(func.count()).select_from(FraudIndicator))
            transaction = session.get(Transaction, "demo-history-coffee-001")
            indicator = session.get(FraudIndicator, "demo-indicator-kyc-vpa")
            assert transaction is not None
            assert indicator is not None
            transaction.amount = Decimal("9999.00")
            indicator.report_count = 99
            session.commit()

        with database.session() as session:
            seed_demo_data(session)
            assert (
                session.scalar(select(func.count()).select_from(Transaction)) == transaction_count
            )
            assert (
                session.scalar(select(func.count()).select_from(FraudIndicator)) == indicator_count
            )
            transaction = session.get(Transaction, "demo-history-coffee-001")
            indicator = session.get(FraudIndicator, "demo-indicator-kyc-vpa")
            assert transaction is not None
            assert indicator is not None
            assert transaction.amount == Decimal("160.00")
            assert indicator.report_count == 3

            transactions = TransactionRepository(session)
            indicators = IndicatorRepository(session)
            assert transactions.has_completed_payment_to(
                "demo-device", " COFFEE.CORNER@OKAXIS "
            )
            assert transactions.typical_completed_amount("demo-device") == Decimal("240.00")
            assert indicators.find_vpa(" SECURE-KYC-UPDATE@OKAXIS ") is not None
    finally:
        database.dispose()


def test_expired_assessments_are_pruned_without_removing_completed_history() -> None:
    database = Database("sqlite://")
    try:
        database.create_schema()
        expired_at = datetime.now(UTC) - timedelta(days=31)
        with database.session() as session:
            completed = Transaction(
                id="completed-history",
                device_id="device-1",
                vpa="known@upi",
                amount=Decimal("100.00"),
                currency="INR",
                status="COMPLETED",
                source="TEST",
                created_at=expired_at,
            )
            assessed = Transaction(
                id="expired-assessment",
                device_id="device-1",
                vpa="unknown@upi",
                amount=Decimal("500.00"),
                currency="INR",
                status="ASSESSED",
                source="TEST",
                created_at=expired_at,
            )
            assessment = RiskAssessment(
                id="expired-risk",
                transaction=assessed,
                score=33,
                level="CAUTION",
                recommended_action="Verify independently.",
                created_at=expired_at,
            )
            assessment.signals = [
                RiskSignalRecord(
                    position=0,
                    code="TEST",
                    label="Expired test signal",
                    weight=33,
                    evidence="Test evidence",
                )
            ]
            session.add_all([completed, assessment])
            session.commit()

            deleted = TransactionRepository(session).delete_expired_assessments(
                retention_days=30
            )

            assert deleted == 1
            assert session.get(Transaction, "completed-history") is not None
            assert session.get(Transaction, "expired-assessment") is None
            assert session.get(RiskAssessment, "expired-risk") is None
            assert session.scalar(select(func.count()).select_from(RiskSignalRecord)) == 0
    finally:
        database.dispose()


def test_stale_refresh_sessions_are_pruned_without_revoking_active_sessions() -> None:
    database = Database("sqlite://")
    try:
        database.create_schema()
        now = datetime.now(UTC)
        with database.session() as session:
            user = User(email="sessions@example.com", display_name="Session Owner")
            session.add(user)
            session.flush()
            session.add_all(
                [
                    RefreshSession(
                        id="expired",
                        user=user,
                        token_hash="a" * 64,
                        expires_at=now - timedelta(minutes=1),
                    ),
                    RefreshSession(
                        id="old-revoked",
                        user=user,
                        token_hash="b" * 64,
                        expires_at=now + timedelta(days=10),
                        revoked_at=now - timedelta(days=8),
                    ),
                    RefreshSession(
                        id="active",
                        user=user,
                        token_hash="c" * 64,
                        expires_at=now + timedelta(days=10),
                    ),
                ]
            )
            session.commit()

            deleted = UserRepository(session).delete_stale_refresh_sessions(now=now)

            assert deleted == 2
            assert session.get(RefreshSession, "expired") is None
            assert session.get(RefreshSession, "old-revoked") is None
            assert session.get(RefreshSession, "active") is not None
    finally:
        database.dispose()
