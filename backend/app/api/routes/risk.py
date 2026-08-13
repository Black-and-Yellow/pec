from __future__ import annotations

from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.api.dependencies import (
    get_context_integrity,
    get_risk_engine,
    get_session,
    get_settings,
)
from app.config import Settings
from app.repositories.indicator_repository import IndicatorRepository
from app.repositories.transaction_repository import TransactionRepository
from app.schemas import RiskLevel, RiskScoreRequest, RiskScoreResponse
from app.services.context_integrity import ContextIntegrityError, ContextIntegrityService
from app.services.risk_engine import RiskEngine, RiskInputs

router = APIRouter(prefix="/risk", tags=["risk"])


def _handoff_policy(
    level: RiskLevel,
) -> Literal["NORMAL", "DELIBERATE_CONFIRMATION", "PAUSED"]:
    if level is RiskLevel.SAFE:
        return "NORMAL"
    if level is RiskLevel.CAUTION:
        return "DELIBERATE_CONFIRMATION"
    return "PAUSED"


@router.post("/score", response_model=RiskScoreResponse)
def score_payment(
    request: RiskScoreRequest,
    session: Annotated[Session, Depends(get_session)],
    engine: Annotated[RiskEngine, Depends(get_risk_engine)],
    settings: Annotated[Settings, Depends(get_settings)],
    integrity: Annotated[ContextIntegrityService, Depends(get_context_integrity)],
) -> RiskScoreResponse:
    try:
        verified_context = integrity.context_for_score(
            request.context, request.context_token
        )
    except ContextIntegrityError as exc:
        raise HTTPException(
            status_code=422,
            detail={
                "code": "INVALID_CONTEXT_INTEGRITY",
                "message": "Context must come from a current FinGuard analysis",
            },
        ) from exc

    transactions = TransactionRepository(session)
    indicators = IndicatorRepository(session)
    transactions.begin_assessment_write()
    known_payee = transactions.has_completed_payment_to(request.device_id, request.payment.vpa)
    assessment = engine.score(
        RiskInputs(
            payment=request.payment,
            known_payee=known_payee,
            typical_amount=transactions.typical_completed_amount(request.device_id),
            indicator=indicators.find_vpa(request.payment.vpa),
            context=verified_context,
        )
    )
    stored = transactions.save_assessment(
        device_id=request.device_id,
        payment=request.payment,
        assessment=assessment,
        retention_days=settings.assessment_retention_days,
        max_assessed_records_total=settings.max_assessed_records_total,
        max_assessed_records_per_device=settings.max_assessed_records_per_device,
    )
    return RiskScoreResponse(
        assessment_id=stored.assessment_id,
        transaction_id=stored.transaction_id,
        payment=request.payment,
        score=assessment.score,
        level=assessment.level,
        signals=assessment.signals,
        recommended_action=assessment.recommended_action,
        requires_confirmation=assessment.level is not RiskLevel.SAFE,
        handoff_policy=_handoff_policy(assessment.level),
        assessed_at=stored.assessed_at,
    )
