from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.api.dependencies import get_optional_user, get_session, get_settings
from app.config import Settings
from app.db.models import User
from app.repositories.reputation_repository import ReputationRepository
from app.repositories.transaction_repository import TransactionRepository
from app.schemas import PreparedResponse, ResponsePrepareRequest
from app.services.response_builder import build_prepared_response

router = APIRouter(prefix="/response", tags=["response"])


@router.post("/prepare", response_model=PreparedResponse)
def prepare_response(
    request: ResponsePrepareRequest,
    session: Annotated[Session, Depends(get_session)],
    settings: Annotated[Settings, Depends(get_settings)],
    user: Annotated[User | None, Depends(get_optional_user)],
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

    # Preparing a report is a person naming this payee as the source of harm,
    # and it caps that address at the bottom band for everyone who checks it.
    # An anonymous caller must not be able to do that: nothing stops one from
    # scoring a payment to any address and immediately reporting it, which
    # would let a stranger brand a rival's VPA in two requests. The draft is
    # still produced for guests - the recovery steps are the point of the
    # screen - but only a signed-in account moves a shared grade, because only
    # that report can be traced back to somebody.
    if user is not None and transactions.mark_reported(assessment.assessment_id):
        ReputationRepository(session).record_report(stored.payment.vpa)
        session.commit()

    return build_prepared_response(
        payment=stored.payment,
        assessment=stored.assessment,
        context=request.context,
        suspicious_message=request.suspicious_message,
        already_paid=request.already_paid,
    )
