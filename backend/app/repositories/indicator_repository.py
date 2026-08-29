from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.models import FraudIndicator


class IndicatorRepository:
    def __init__(self, session: Session) -> None:
        self._session = session

    def find_vpa(self, vpa: str) -> FraudIndicator | None:
        statement = select(FraudIndicator).where(
            FraudIndicator.indicator_type == "VPA",
            FraudIndicator.normalized_value == vpa.strip().lower(),
        )
        return self._session.scalar(statement)
