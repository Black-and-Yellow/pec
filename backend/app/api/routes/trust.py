from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.dependencies import get_session
from app.repositories.indicator_repository import IndicatorRepository
from app.repositories.reputation_repository import ReputationRepository
from app.schemas import TrustLookupRequest, TrustLookupResponse
from app.services.trust_score import TrustInputs, TrustScorer

router = APIRouter(prefix="/trust", tags=["trust"])


@router.post("/lookup", response_model=TrustLookupResponse)
def lookup_payee_trust(
    request: TrustLookupRequest,
    session: Annotated[Session, Depends(get_session)],
) -> TrustLookupResponse:
    """Report a payee's standing without scoring or storing a payment.

    A lookup is a read. It deliberately does not touch the reputation ledger:
    if simply asking about an address counted as an encounter with it, the
    ledger would measure curiosity rather than use, and anyone could inflate a
    scam address into a well-established one by querying it in a loop.
    """
    indicator = IndicatorRepository(session).find_vpa(request.vpa)
    trust = TrustScorer().score(
        TrustInputs(
            vpa=request.vpa,
            reputation=ReputationRepository(session).snapshot(request.vpa),
            seeded_indicator_label=indicator.label if indicator is not None else None,
        )
    )
    return TrustLookupResponse(trust=trust)
