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
from app.integrations.gemini_client import GeminiClient
from app.repositories.indicator_repository import IndicatorRepository
from app.repositories.reputation_repository import ReputationRepository
from app.repositories.transaction_repository import TransactionRepository
from app.schemas import (
    RiskExplainRequest,
    RiskExplainResponse,
    RiskLevel,
    RiskScoreRequest,
    RiskScoreResponse,
)
from app.services.context_integrity import ContextIntegrityError, ContextIntegrityService
from app.services.explanation_service import ExplanationService
from app.services.risk_engine import RiskEngine, RiskInputs
from app.services.trust_score import TrustInputs, TrustScorer

router = APIRouter(prefix="/risk", tags=["risk"])


def _handoff_policy(
    level: RiskLevel,
) -> Literal["NORMAL", "DELIBERATE_CONFIRMATION", "PAUSED"]:
    if level is RiskLevel.SAFE:
        return "NORMAL"
    if level is RiskLevel.CAUTION:
        return "DELIBERATE_CONFIRMATION"
    return "PAUSED"


def _explanation_service(settings: Settings) -> ExplanationService:
    gemini_client = None
    if settings.enable_ai_context and settings.gemini_api_key:
        gemini_client = GeminiClient(
            api_key=settings.gemini_api_key,
            model=settings.gemini_model,
            timeout_seconds=settings.gemini_timeout_seconds,
        )
    return ExplanationService(
        gemini_client=gemini_client,
        enabled=settings.enable_ai_context,
    )


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
    reputation = ReputationRepository(session)
    transactions.begin_assessment_write()
    known_payee = transactions.has_completed_payment_to(request.device_id, request.payment.vpa)
    indicator = indicators.find_vpa(request.payment.vpa)
    # Read the payee's standing before this check is folded into it, so a
    # payer's own first look at an address can never be the evidence that the
    # address is well established.
    payee_trust = TrustScorer().score(
        TrustInputs(
            vpa=request.payment.vpa,
            reputation=reputation.snapshot(request.payment.vpa),
            seeded_indicator_label=indicator.label if indicator is not None else None,
        )
    )
    assessment = engine.score(
        RiskInputs(
            payment=request.payment,
            known_payee=known_payee,
            typical_amount=transactions.typical_completed_amount(request.device_id),
            indicator=indicator,
            context=verified_context,
            environment=request.environment,
            payee_trust=payee_trust,
        )
    )
    reputation.observe_check(
        vpa=request.payment.vpa,
        device_id=request.device_id,
        level=assessment.level,
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
        payee_trust=payee_trust,
        score=assessment.score,
        level=assessment.level,
        signals=assessment.signals,
        recommended_action=assessment.recommended_action,
        requires_confirmation=assessment.level is not RiskLevel.SAFE,
        handoff_policy=_handoff_policy(assessment.level),
        assessed_at=stored.assessed_at,
    )


@router.post("/explain", response_model=RiskExplainResponse)
async def explain_assessment(
    request: RiskExplainRequest,
    session: Annotated[Session, Depends(get_session)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> RiskExplainResponse:
    stored = TransactionRepository(session).get_assessment(
        request.assessment_id,
        retention_days=settings.assessment_retention_days,
    )
    if stored is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "ASSESSMENT_NOT_FOUND",
                "message": "The requested risk assessment was not found",
            },
        )

    return await _explanation_service(settings).explain(
        payment=stored.payment,
        assessment=stored.assessment,
        consent_to_external_ai=request.consent_to_external_ai,
    )
