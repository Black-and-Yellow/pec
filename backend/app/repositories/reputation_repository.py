"""Reads and writes the payee reputation ledger that backs the trust score."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db.models import PayeeDeviceObservation, PayeeReputation
from app.repositories.transaction_repository import hash_device_identifier
from app.schemas import RiskLevel

RECENT_WINDOW_DAYS = 7
# A single payee cannot pin more device rows than this. Reach saturates the
# score long before the cap, so the bound costs no accuracy and keeps one
# widely-scanned merchant QR from dominating the table.
MAX_DEVICE_OBSERVATIONS_PER_PAYEE = 500


@dataclass(frozen=True, slots=True)
class ReputationSnapshot:
    """What the network knows about one payee at the moment of a check."""

    vpa: str
    first_seen_at: datetime | None
    last_seen_at: datetime | None
    check_count: int
    distinct_device_count: int
    safe_count: int
    caution_count: int
    high_count: int
    reported_count: int
    recent_new_device_count: int

    @property
    def is_unknown(self) -> bool:
        return self.check_count == 0

    @property
    def observed_days(self) -> int:
        if self.first_seen_at is None:
            return 0
        delta = datetime.now(UTC) - _as_utc(self.first_seen_at)
        return max(0, delta.days)

    @property
    def adverse_count(self) -> int:
        return self.high_count + self.reported_count


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def unknown_snapshot(vpa: str) -> ReputationSnapshot:
    return ReputationSnapshot(
        vpa=vpa.strip().lower(),
        first_seen_at=None,
        last_seen_at=None,
        check_count=0,
        distinct_device_count=0,
        safe_count=0,
        caution_count=0,
        high_count=0,
        reported_count=0,
        recent_new_device_count=0,
    )


def _new_reputation(vpa: str, moment: datetime) -> PayeeReputation:
    """Build a zeroed row.

    Column defaults only materialise at INSERT, and this row is read and
    incremented in the same unit of work that creates it, so every counter is
    set here rather than left to the database.
    """
    return PayeeReputation(
        vpa=vpa,
        first_seen_at=moment,
        last_seen_at=moment,
        recent_window_started_at=moment,
        check_count=0,
        distinct_device_count=0,
        safe_count=0,
        caution_count=0,
        high_count=0,
        reported_count=0,
        recent_new_device_count=0,
    )


class ReputationRepository:
    def __init__(self, session: Session) -> None:
        self._session = session

    def snapshot(self, vpa: str) -> ReputationSnapshot:
        normalized = vpa.strip().lower()
        record = self._session.get(PayeeReputation, normalized)
        if record is None:
            return unknown_snapshot(normalized)
        return self._to_snapshot(record)

    def observe_check(
        self,
        *,
        vpa: str,
        device_id: str,
        level: RiskLevel,
        now: datetime | None = None,
    ) -> ReputationSnapshot:
        """Record one completed check and return the standing *before* it.

        The snapshot is taken before the counters move so a payee's own check
        can never be the evidence that the payee is well established. The
        first device ever to see a scam VPA must still be told it is new.
        """
        moment = now or datetime.now(UTC)
        normalized = vpa.strip().lower()
        device_key = hash_device_identifier(device_id)

        record = self._session.get(PayeeReputation, normalized)
        if record is None:
            record = _new_reputation(normalized, moment)
            self._session.add(record)
        prior = self._to_snapshot(record)

        if _as_utc(record.recent_window_started_at) < moment - timedelta(
            days=RECENT_WINDOW_DAYS
        ):
            record.recent_new_device_count = 0
            record.recent_window_started_at = moment

        if self._register_device(normalized, device_key, moment):
            record.distinct_device_count += 1
            record.recent_new_device_count += 1

        record.check_count += 1
        record.last_seen_at = moment
        if level is RiskLevel.SAFE:
            record.safe_count += 1
        elif level is RiskLevel.CAUTION:
            record.caution_count += 1
        else:
            record.high_count += 1
        return prior

    def _register_device(self, vpa: str, device_key: str, moment: datetime) -> bool:
        existing = self._session.scalar(
            select(PayeeDeviceObservation.id).where(
                PayeeDeviceObservation.vpa == vpa,
                PayeeDeviceObservation.device_key == device_key,
            )
        )
        if existing is not None:
            return False
        observed = (
            self._session.scalar(
                select(func.count(PayeeDeviceObservation.id)).where(
                    PayeeDeviceObservation.vpa == vpa
                )
            )
            or 0
        )
        if observed >= MAX_DEVICE_OBSERVATIONS_PER_PAYEE:
            return False
        self._session.add(
            PayeeDeviceObservation(
                vpa=vpa,
                device_key=device_key,
                first_seen_at=moment,
            )
        )
        return True

    @staticmethod
    def _to_snapshot(record: PayeeReputation) -> ReputationSnapshot:
        return ReputationSnapshot(
            vpa=record.vpa,
            first_seen_at=_as_utc(record.first_seen_at),
            last_seen_at=_as_utc(record.last_seen_at),
            check_count=record.check_count,
            distinct_device_count=record.distinct_device_count,
            safe_count=record.safe_count,
            caution_count=record.caution_count,
            high_count=record.high_count,
            reported_count=record.reported_count,
            recent_new_device_count=record.recent_new_device_count,
        )
