from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.api.dependencies import get_session, get_settings
from app.config import Settings
from app.repositories.transaction_repository import TransactionRepository
from app.schemas import PreparedResponse, ResponsePrepareRequest
from app.services.response_builder import build_prepared_response

router = APIRouter(prefix="/response", tags=["response"])


@router.post("/prepare", response_model=PreparedResponse)
def prepare_response(
    request: ResponsePrepareRequest,
    session: Annotated[Session, Depends(get_session)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> PreparedResponse:
    assessment = request.assessment
    if assessment.assessment_id is None:
        raise HTTPException(
            status_code=422,
            detail={
                "code": "ASSESSMENT_ID_REQUIRED",
                "message": "Prepare a response from a saved FinGuard risk assessment",
            },
        )

    transactions = TransactionRepository(session)
    stored = transactions.get_assessment(
        assessment.assessment_id,
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
    if stored.payment != request.payment:
        raise HTTPException(
            status_code=409,
            detail={
                "code": "ASSESSMENT_PAYMENT_MISMATCH",
                "message": "The payment does not match the saved risk assessment",
            },
        )

    # Nothing here writes to shared reputation, for anyone, ever.
    #
    # This endpoint produces a private draft. Reading what a report would say
    # is not consent to publish one: a user may open the screen to understand
    # their options, to copy the wording, or by mistake, and none of those is
    # a decision to mark a third party publicly. Gating it behind a signed-in
    # account was not enough either - it still turned an exploratory tap into
    # a permanent, visible accusation.
    #
    # Publishing belongs to a submission endpoint that does not exist yet, and
    # would need verified identity, an explicit opt-in, confirmation that the
    # payment actually happened, one report per person per address, rate
    # limiting and a moderation path. Until all of that exists, the honest
    # behaviour is to write nothing.

    return build_prepared_response(
        payment=stored.payment,
        assessment=stored.assessment,
        context=request.context,
        suspicious_message=request.suspicious_message,
        already_paid=request.already_paid,
    )
