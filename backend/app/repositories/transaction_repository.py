from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from hashlib import sha256
from statistics import median
from typing import Any, cast

from sqlalchemy import delete, desc, func, select
from sqlalchemy.engine import CursorResult
from sqlalchemy.orm import Session, selectinload

from app.db.models import RiskAssessment, RiskSignalRecord, Transaction
from app.schemas import PaymentDetails, RiskAssessmentPayload, RiskLevel, RiskSignal

_DEVICE_IDENTIFIER_HASH_DOMAIN = b"FinGuard device identifier v1\x00"
# Dollar signs cannot appear in a validated client capability, so a stored digest
# cannot itself be replayed through the bounded legacy-identifier compatibility path.
_DEVICE_IDENTIFIER_HASH_PREFIX = "sha256$v1$"
_DELETE_BATCH_SIZE = 500


def hash_device_identifier(device_id: str) -> str:
    digest = sha256(_DEVICE_IDENTIFIER_HASH_DOMAIN + device_id.encode("utf-8")).hexdigest()
    return f"{_DEVICE_IDENTIFIER_HASH_PREFIX}{digest}"


def _device_storage_keys(device_id: str) -> tuple[str, str]:
    """Return the current at-rest key plus the exact pre-hash legacy key."""
    return hash_device_identifier(device_id), device_id


@dataclass(frozen=True, slots=True)
class StoredAssessment:
    assessment_id: str
    transaction_id: str
    assessed_at: datetime
    payment: PaymentDetails
    assessment: RiskAssessmentPayload


class TransactionRepository:
    def __init__(self, session: Session) -> None:
        self._session = session

    def begin_assessment_write(self) -> None:
        """Serialize the bounded read/score/write unit in the SQLite deployment."""
        self._session.connection().exec_driver_sql("BEGIN IMMEDIATE")

    def has_completed_payment_to(self, device_id: str, vpa: str) -> bool:
        statement = (
            select(Transaction.id)
            .where(
                Transaction.device_id.in_(_device_storage_keys(device_id)),
                Transaction.vpa == vpa.strip().lower(),
                Transaction.status == "COMPLETED",
            )
            .limit(1)
        )
        return self._session.scalar(statement) is not None

    def typical_completed_amount(self, device_id: str) -> Decimal | None:
        statement = select(Transaction.amount).where(
            Transaction.device_id.in_(_device_storage_keys(device_id)),
            Transaction.status == "COMPLETED",
            Transaction.amount.is_not(None),
        )
        amounts = [amount for amount in self._session.scalars(statement) if amount is not None]
        return Decimal(median(amounts)) if amounts else None

    def delete_expired_assessments(
        self,
        *,
        retention_days: int,
        now: datetime | None = None,
    ) -> int:
        deleted = self._delete_expired_assessments(
            retention_days=retention_days,
            now=now or datetime.now(UTC),
        )
        self._session.commit()
        return deleted

    def delete_expired_assessments_batch(
        self,
        *,
        retention_days: int,
        now: datetime | None = None,
    ) -> int:
        """Delete one bounded batch for periodic lifecycle maintenance."""
        cutoff = (now or datetime.now(UTC)) - timedelta(days=retention_days)
        transaction_ids = list(
            self._session.scalars(
                select(Transaction.id)
                .where(
                    Transaction.status == "ASSESSED",
                    Transaction.created_at < cutoff,
                )
                .order_by(Transaction.created_at, Transaction.id)
                .limit(_DELETE_BATCH_SIZE)
            )
        )
        deleted = self._delete_assessed_transactions(transaction_ids)
        self._session.commit()
        return deleted

    def save_assessment(
        self,
        *,
        device_id: str,
        payment: PaymentDetails,
        assessment: RiskAssessmentPayload,
        retention_days: int = 30,
        max_assessed_records_total: int = 5_000,
        max_assessed_records_per_device: int = 50,
    ) -> StoredAssessment:
        now = datetime.now(UTC)
        device_storage_keys = _device_storage_keys(device_id)

        # The route starts an immediate SQLite transaction before its scoring reads.
        # Reserve capacity before adding the new assessment so the committed state
        # cannot exceed either configured budget.
        self._delete_expired_assessments(retention_days=retention_days, now=now)
        self._prune_assessments_to_limit(
            maximum=max_assessed_records_per_device - 1,
            device_storage_keys=device_storage_keys,
        )
        self._prune_assessments_to_limit(maximum=max_assessed_records_total - 1)

        transaction = Transaction(
            device_id=device_storage_keys[0],
            vpa=payment.vpa,
            payee_name=payment.payee_name,
            amount=payment.amount,
            transaction_note=payment.transaction_note,
            currency=payment.currency,
            transaction_reference=payment.transaction_reference,
            status="ASSESSED",
            source="FINGUARD_ASSESSMENT",
            created_at=now,
        )
        risk_assessment = RiskAssessment(
            transaction=transaction,
            score=assessment.score,
            level=assessment.level.value,
            recommended_action=assessment.recommended_action,
            created_at=now,
        )
        risk_assessment.signals = [
            RiskSignalRecord(
                position=position,
                code=signal.code,
                label=signal.label,
                weight=signal.weight,
                evidence=signal.evidence,
            )
            for position, signal in enumerate(assessment.signals)
        ]
        self._session.add(risk_assessment)
        self._session.commit()
        self._session.refresh(risk_assessment)
        return self._to_stored(risk_assessment)

    def get_assessment(
        self,
        assessment_id: str,
        *,
        retention_days: int,
        now: datetime | None = None,
    ) -> StoredAssessment | None:
        cutoff = (now or datetime.now(UTC)) - timedelta(days=retention_days)
        statement = (
            select(RiskAssessment)
            .options(selectinload(RiskAssessment.signals), selectinload(RiskAssessment.transaction))
            .join(RiskAssessment.transaction)
            .where(
                RiskAssessment.id == assessment_id,
                Transaction.status == "ASSESSED",
                Transaction.created_at >= cutoff,
            )
        )
        record = self._session.scalar(statement)
        return self._to_stored(record) if record else None

    def list_assessments(
        self,
        device_id: str,
        *,
        limit: int,
        retention_days: int,
        now: datetime | None = None,
    ) -> list[StoredAssessment]:
        cutoff = (now or datetime.now(UTC)) - timedelta(days=retention_days)
        statement = (
            select(RiskAssessment)
            .join(RiskAssessment.transaction)
            .options(selectinload(RiskAssessment.signals), selectinload(RiskAssessment.transaction))
            .where(
                Transaction.device_id.in_(_device_storage_keys(device_id)),
                Transaction.status == "ASSESSED",
                Transaction.created_at >= cutoff,
            )
            .order_by(desc(RiskAssessment.created_at), desc(RiskAssessment.id))
            .limit(limit)
        )
        return [self._to_stored(record) for record in self._session.scalars(statement)]

    def _delete_expired_assessments(self, *, retention_days: int, now: datetime) -> int:
        cutoff = now - timedelta(days=retention_days)
        deleted = 0
        while True:
            transaction_ids = list(
                self._session.scalars(
                    select(Transaction.id)
                    .where(
                        Transaction.status == "ASSESSED",
                        Transaction.created_at < cutoff,
                    )
                    .order_by(Transaction.created_at, Transaction.id)
                    .limit(_DELETE_BATCH_SIZE)
                )
            )
            if not transaction_ids:
                return deleted
            batch_deleted = self._delete_assessed_transactions(transaction_ids)
            if batch_deleted == 0:
                return deleted
            deleted += batch_deleted

    def _prune_assessments_to_limit(
        self,
        *,
        maximum: int,
        device_storage_keys: tuple[str, str] | None = None,
    ) -> int:
        count_statement = select(func.count(Transaction.id)).where(
            Transaction.status == "ASSESSED"
        )
        if device_storage_keys is not None:
            count_statement = count_statement.where(
                Transaction.device_id.in_(device_storage_keys)
            )
        current_count = self._session.scalar(count_statement) or 0
        excess = max(0, current_count - maximum)
        deleted = 0

        while excess > 0:
            transaction_ids_statement = select(Transaction.id).where(
                Transaction.status == "ASSESSED"
            )
            if device_storage_keys is not None:
                transaction_ids_statement = transaction_ids_statement.where(
                    Transaction.device_id.in_(device_storage_keys)
                )
            transaction_ids = list(
                self._session.scalars(
                    transaction_ids_statement
                    .order_by(Transaction.created_at, Transaction.id)
                    .limit(min(excess, _DELETE_BATCH_SIZE))
                )
            )
            if not transaction_ids:
                return deleted
            batch_deleted = self._delete_assessed_transactions(transaction_ids)
            if batch_deleted == 0:
                return deleted
            deleted += batch_deleted
            excess -= batch_deleted

        return deleted

    def _delete_assessed_transactions(self, transaction_ids: list[str]) -> int:
        assessment_ids = select(RiskAssessment.id).where(
            RiskAssessment.transaction_id.in_(transaction_ids)
        )
        self._session.execute(
            delete(RiskSignalRecord).where(
                RiskSignalRecord.assessment_id.in_(assessment_ids)
            )
        )
        self._session.execute(
            delete(RiskAssessment).where(
                RiskAssessment.transaction_id.in_(transaction_ids)
            )
        )
        result = self._session.execute(
            delete(Transaction).where(
                Transaction.id.in_(transaction_ids),
                Transaction.status == "ASSESSED",
            )
        )
        return cast(CursorResult[Any], result).rowcount or 0

    @staticmethod
    def _to_stored(record: RiskAssessment) -> StoredAssessment:
        transaction = record.transaction
        payment = PaymentDetails(
            vpa=transaction.vpa,
            payee_name=transaction.payee_name,
            amount=transaction.amount,
            transaction_note=transaction.transaction_note,
            currency=transaction.currency,
            transaction_reference=transaction.transaction_reference,
        )
        assessment = RiskAssessmentPayload(
            assessment_id=record.id,
            score=record.score,
            level=RiskLevel(record.level),
            signals=[
                RiskSignal(
                    code=signal.code,
                    label=signal.label,
                    weight=signal.weight,
                    evidence=signal.evidence,
                )
                for signal in record.signals
            ],
            recommended_action=record.recommended_action,
        )
        return StoredAssessment(
            assessment_id=record.id,
            transaction_id=transaction.id,
            assessed_at=TransactionRepository._as_utc(record.created_at),
            payment=payment,
            assessment=assessment,
        )

    @staticmethod
    def _as_utc(value: datetime) -> datetime:
        if value.tzinfo is None:
            return value.replace(tzinfo=UTC)
        return value.astimezone(UTC)
