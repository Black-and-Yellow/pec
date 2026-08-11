from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from statistics import median

from sqlalchemy import delete, desc, select
from sqlalchemy.orm import Session, selectinload

from app.db.models import RiskAssessment, RiskSignalRecord, Transaction
from app.schemas import PaymentDetails, RiskAssessmentPayload, RiskLevel, RiskSignal


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

    def has_completed_payment_to(self, device_id: str, vpa: str) -> bool:
        statement = (
            select(Transaction.id)
            .where(
                Transaction.device_id == device_id,
                Transaction.vpa == vpa.strip().lower(),
                Transaction.status == "COMPLETED",
            )
            .limit(1)
        )
        return self._session.scalar(statement) is not None

    def typical_completed_amount(self, device_id: str) -> Decimal | None:
        statement = select(Transaction.amount).where(
            Transaction.device_id == device_id,
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
        cutoff = (now or datetime.now(UTC)) - timedelta(days=retention_days)
        expired_transaction_ids = select(Transaction.id).where(
            Transaction.status == "ASSESSED",
            Transaction.created_at < cutoff,
        )
        expired_assessment_ids = select(RiskAssessment.id).where(
            RiskAssessment.transaction_id.in_(expired_transaction_ids)
        )
        self._session.execute(
            delete(RiskSignalRecord).where(
                RiskSignalRecord.assessment_id.in_(expired_assessment_ids)
            )
        )
        self._session.execute(
            delete(RiskAssessment).where(
                RiskAssessment.transaction_id.in_(expired_transaction_ids)
            )
        )
        result = self._session.execute(
            delete(Transaction).where(Transaction.id.in_(expired_transaction_ids))
        )
        self._session.commit()
        return result.rowcount or 0

    def save_assessment(
        self,
        *,
        device_id: str,
        payment: PaymentDetails,
        assessment: RiskAssessmentPayload,
    ) -> StoredAssessment:
        transaction = Transaction(
            device_id=device_id,
            vpa=payment.vpa,
            payee_name=payment.payee_name,
            amount=payment.amount,
            transaction_note=payment.transaction_note,
            currency=payment.currency,
            transaction_reference=payment.transaction_reference,
            status="ASSESSED",
            source="FINGUARD_ASSESSMENT",
        )
        risk_assessment = RiskAssessment(
            transaction=transaction,
            score=assessment.score,
            level=assessment.level.value,
            recommended_action=assessment.recommended_action,
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

    def get_assessment(self, assessment_id: str) -> StoredAssessment | None:
        statement = (
            select(RiskAssessment)
            .options(selectinload(RiskAssessment.signals), selectinload(RiskAssessment.transaction))
            .where(RiskAssessment.id == assessment_id)
        )
        record = self._session.scalar(statement)
        return self._to_stored(record) if record else None

    def list_assessments(self, device_id: str, limit: int) -> list[StoredAssessment]:
        statement = (
            select(RiskAssessment)
            .join(RiskAssessment.transaction)
            .options(selectinload(RiskAssessment.signals), selectinload(RiskAssessment.transaction))
            .where(Transaction.device_id == device_id)
            .order_by(desc(RiskAssessment.created_at), desc(RiskAssessment.id))
            .limit(limit)
        )
        return [self._to_stored(record) for record in self._session.scalars(statement)]

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
