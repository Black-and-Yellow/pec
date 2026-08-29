from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query
from sqlalchemy.orm import Session

from app.api.dependencies import get_session, get_settings
from app.config import Settings
from app.repositories.transaction_repository import TransactionRepository
from app.schemas import DEVICE_ID_PATTERN, HistoryItem, HistoryResponse

router = APIRouter(tags=["history"])
HISTORY_DEVICE_HEADER = "X-FinGuard-Device-ID"


@router.get("/history", response_model=HistoryResponse)
def history(
    session: Annotated[Session, Depends(get_session)],
    settings: Annotated[Settings, Depends(get_settings)],
    device_id: Annotated[
        str,
        Header(
            alias=HISTORY_DEVICE_HEADER,
            min_length=3,
            max_length=128,
            pattern=DEVICE_ID_PATTERN.pattern,
        ),
    ],
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
) -> HistoryResponse:
    records = TransactionRepository(session).list_assessments(
        device_id,
        limit=limit,
        retention_days=settings.assessment_retention_days,
    )
    items = [
        HistoryItem(
            assessment_id=record.assessment_id,
            transaction_id=record.transaction_id,
            assessed_at=record.assessed_at,
            payment=record.payment,
            score=record.assessment.score,
            level=record.assessment.level,
            signals=record.assessment.signals,
            recommended_action=record.assessment.recommended_action,
        )
        for record in records
    ]
    return HistoryResponse(items=items, count=len(items))
